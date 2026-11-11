import Foundation
#if canImport(CoreNFC)
@preconcurrency import CoreNFC
#endif

/// Reads the user authentication certificate from a My Number card.
///
/// The kit sends only SELECT and READ BINARY, never a PIN, and returns only the
/// issuer and the validity period. A host app calls ``availability(bundle:)``
/// before showing a read button and ``readCertificateSummary()`` when the person taps it.
public struct CardReader: Sendable {
    /// The kit's version, for support logs. It changes with every public API change.
    public static let version = "0.1.0"

    public enum Source: Equatable, Sendable {
        /// A real card through Core NFC.
        case nfc
        /// A synthetic card for building screens on the simulator.
        case demo(DemoCard)
    }

    /// The words the system NFC sheet shows. The defaults are Japanese.
    public struct Messages: Equatable, Sendable {
        public var hold: String
        public var reading: String
        public var done: String
        public var multipleCards: String
        public var unsupportedCard: String
        public var failed: String

        public init(
            hold: String = "マイナンバーカードを iPhone の上部に当ててください",
            reading: String = "読み取っています。カードを動かさないでください",
            done: String = "読み取りました",
            multipleCards: String = "カードを 1 枚だけ当ててください",
            unsupportedCard: String = "このカードには対応していません",
            failed: String = "読み取れませんでした"
        ) {
            self.hold = hold
            self.reading = reading
            self.done = done
            self.multipleCards = multipleCards
            self.unsupportedCard = unsupportedCard
            self.failed = failed
        }
    }

    public let source: Source
    public let messages: Messages

    public init(source: Source = .nfc, messages: Messages = Messages()) {
        self.source = source
        self.messages = messages
    }

    /// Whether this app on this device can read a card. A demo source is always available.
    public func availability(bundle: Bundle = .main) -> Availability {
        if case .demo = source { return .available }
        return Availability.check(infoDictionary: bundle.infoDictionary, readingSupported: Self.readingSupported)
    }

    /// Opens the system NFC sheet, reads the card and returns the certificate's issuer and validity.
    public func readCertificateSummary() async throws(CardReadError) -> CertificateSummary {
        let certificate: Data
        switch source {
        case .demo(let card):
            certificate = try await JPKIReader(transport: DemoTransport(card: card, now: Date())).readAuthenticationCertificate()
        case .nfc:
            if case .unavailable(let reason) = availability() { throw .unavailable(reason) }
            #if canImport(CoreNFC)
            certificate = try await NFCCertificateSession(messages: messages).read()
            #else
            throw .unavailable(.readingUnsupported)
            #endif
        }
        return try CertificateSummary(certificate: certificate)
    }

    private static var readingSupported: Bool {
        #if canImport(CoreNFC) && !targetEnvironment(simulator)
        NFCTagReaderSession.readingAvailable
        #else
        false
        #endif
    }
}
