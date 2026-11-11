#if canImport(CoreNFC)
@preconcurrency import CoreNFC
import Foundation

/// One NFC sheet from open to close. It finishes exactly once, however the sheet ends.
final class NFCCertificateSession: NSObject, NFCTagReaderSessionDelegate, @unchecked Sendable {
    // Every mutable property is touched only on `queue`, which is also the delegate queue.
    private let queue = DispatchQueue(label: "ICReadKit.NFCCertificateSession")
    private let messages: CardReader.Messages
    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<Result<Data, CardReadError>, Never>?

    init(messages: CardReader.Messages) {
        self.messages = messages
    }

    func read() async throws(CardReadError) -> Data {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, CardReadError>, Never>) in
            queue.async {
                self.continuation = continuation
                guard let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: self.queue) else {
                    self.finish(.failure(.unavailable(.readingUnsupported)))
                    return
                }
                session.alertMessage = self.messages.hold
                self.session = session
                session.begin()
            }
        }
        return try result.get()
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: any Error) {
        // Also called after a successful read invalidates the sheet; `finish` ignores that second call.
        finish(.failure(Self.map(error)))
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = messages.multipleCards
            queue.asyncAfter(deadline: .now() + 0.5) { self.session?.restartPolling() }
            return
        }
        guard case .iso7816(let card) = tag else {
            session.invalidate(errorMessage: messages.unsupportedCard)
            finish(.failure(.unsupportedCard))
            return
        }
        let reader = JPKIReader(transport: ISO7816TagTransport(tag: card))
        session.connect(to: tag) { [self] error in
            // Core NFC calls this on the delegate queue, so `self.session` is safe to touch here.
            if let error {
                self.session?.invalidate(errorMessage: messages.failed)
                finish(.failure(Self.map(error)))
                return
            }
            self.session?.alertMessage = messages.reading
            Task {
                let result: Result<Data, CardReadError>
                do throws(CardReadError) {
                    result = .success(try await reader.readAuthenticationCertificate())
                } catch {
                    result = .failure(error)
                }
                self.queue.async { self.complete(result) }
            }
        }
    }

    /// Closes the sheet with the right words and reports the result. Runs on `queue`.
    private func complete(_ result: Result<Data, CardReadError>) {
        switch result {
        case .success:
            session?.alertMessage = messages.done
            session?.invalidate()
        case .failure(let error):
            session?.invalidate(errorMessage: error == .unsupportedCard ? messages.unsupportedCard : messages.failed)
        }
        finish(result)
    }

    private func finish(_ result: Result<Data, CardReadError>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(returning: result)
    }

    static func map(_ error: any Error) -> CardReadError {
        if let error = error as? CardReadError { return error }
        guard let nfcError = error as? NFCReaderError else { return .system(code: (error as NSError).code) }
        switch nfcError.code {
        case .readerSessionInvalidationErrorUserCanceled: return .cancelled
        case .readerSessionInvalidationErrorSessionTimeout: return .timeout
        case .readerTransceiveErrorTagConnectionLost, .readerTransceiveErrorTagNotConnected,
             .readerTransceiveErrorRetryExceeded:
            return .connectionLost
        case .readerErrorUnsupportedFeature: return .unavailable(.readingUnsupported)
        default: return .system(code: nfcError.code.rawValue)
        }
    }
}

/// Sends command APDUs to a connected ISO 7816 tag.
struct ISO7816TagTransport: CardTransport, @unchecked Sendable {
    let tag: any NFCISO7816Tag

    func transmit(_ command: CommandAPDU) async throws(CardReadError) -> ResponseAPDU {
        let apdu = NFCISO7816APDU(
            instructionClass: command.cla,
            instructionCode: command.ins,
            p1Parameter: command.p1,
            p2Parameter: command.p2,
            data: command.data,
            expectedResponseLength: command.expectedLength ?? -1
        )
        do {
            let (data, sw1, sw2) = try await tag.sendCommand(apdu: apdu)
            return ResponseAPDU(data: data, sw1: sw1, sw2: sw2)
        } catch {
            throw NFCCertificateSession.map(error)
        }
    }
}
#endif
