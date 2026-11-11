import Foundation
import PassKit
import Testing
@testable import ICReadKit

/// Replays scripted responses and records every command it receives.
final class ScriptedTransport: CardTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<ResponseAPDU, CardReadError>]
    private(set) var sent: [CommandAPDU] = []

    init(_ responses: [Result<ResponseAPDU, CardReadError>]) { self.responses = responses }

    func transmit(_ command: CommandAPDU) async throws(CardReadError) -> ResponseAPDU {
        let next: Result<ResponseAPDU, CardReadError> = lock.withLock {
            sent.append(command)
            return responses.isEmpty ? .failure(.connectionLost) : responses.removeFirst()
        }
        return try next.get()
    }
}

private func ok(_ data: Data = Data()) -> Result<ResponseAPDU, CardReadError> { .success(ResponseAPDU(data: data, sw1: 0x90, sw2: 0x00)) }
private func status(_ sw1: UInt8, _ sw2: UInt8) -> Result<ResponseAPDU, CardReadError> { .success(ResponseAPDU(data: Data(), sw1: sw1, sw2: sw2)) }
private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Suite struct CommandTests {
    @Test func selectingTheJPKIApplicationMatchesThePublishedBytes() {
        #expect(CommandAPDU.selectApplication(JPKI.applicationIdentifier).bytes
            == Data([0x00, 0xA4, 0x04, 0x0C, 0x0A, 0xD3, 0x92, 0xF0, 0x00, 0x26, 0x01, 0x00, 0x00, 0x00, 0x01]))
    }

    @Test func selectingTheCertificateFileUsesItsTwoByteIdentifier() {
        #expect(CommandAPDU.selectFile(JPKI.authenticationCertificateFile).bytes == Data([0x00, 0xA4, 0x02, 0x0C, 0x02, 0x00, 0x0A]))
    }

    @Test func readBinaryPutsTheOffsetInP1P2AndSends256AsZero() {
        #expect(CommandAPDU.readBinary(offset: 0x0104, length: 256).bytes == Data([0x00, 0xB0, 0x01, 0x04, 0x00]))
        #expect(CommandAPDU.readBinary(offset: 0, length: 4).bytes == Data([0x00, 0xB0, 0x00, 0x00, 0x04]))
    }

    @Test func theKitCanOnlyBuildSelectAndReadBinary() {
        // VERIFY (0x20), CHANGE REFERENCE DATA (0x24) and RESET RETRY COUNTER (0x2C) touch PINs and must stay unbuildable.
        #expect(CommandAPDU.Instruction.allowed == [0xA4, 0xB0])
        let built = [
            CommandAPDU.selectApplication(JPKI.applicationIdentifier),
            .selectFile(JPKI.authenticationCertificateFile),
            .readBinary(offset: 0, length: 1),
        ]
        #expect(built.allSatisfy { CommandAPDU.Instruction.allowed.contains($0.ins) })
    }
}

@Suite struct ReaderTests {
    @Test func readsTheCertificateInChunksFromTheHeaderLength() async throws {
        let certificate = SyntheticCertificate.make(card: .valid, now: date("2026-11-11T00:00:00Z"))
        #expect(certificate.count > 512)
        var responses = [ok(), ok(), ok(certificate.prefix(4))]
        var expected: [CommandAPDU] = [
            .selectApplication(JPKI.applicationIdentifier),
            .selectFile(JPKI.authenticationCertificateFile),
            .readBinary(offset: 0, length: 4),
        ]
        var offset = 4
        while offset < certificate.count {
            let end = min(certificate.count, offset + 256)
            expected.append(.readBinary(offset: offset, length: end - offset))
            responses.append(ok(certificate.subdata(in: offset..<end)))
            offset = end
        }
        let transport = ScriptedTransport(responses)

        let read = try await JPKIReader(transport: transport).readAuthenticationCertificate()

        #expect(read == certificate)
        #expect(transport.sent == expected)
    }

    @Test func aCardWithoutTheApplicationIsUnsupportedNotACrash() async {
        let transport = ScriptedTransport([status(0x6A, 0x82)])
        await #expect(throws: CardReadError.unsupportedCard) {
            try await JPKIReader(transport: transport).readAuthenticationCertificate()
        }
        #expect(transport.sent.count == 1)
    }

    @Test func otherRefusalsKeepTheirStatusWord() async {
        let transport = ScriptedTransport([ok(), status(0x69, 0x82)])
        await #expect(throws: CardReadError.cardRejected(statusWord: 0x6982)) {
            try await JPKIReader(transport: transport).readAuthenticationCertificate()
        }
    }

    @Test func aHeaderThatIsNotACertificateStopsTheRead() async {
        let transport = ScriptedTransport([ok(), ok(), ok(Data([0x04, 0x82, 0x01, 0x00]))])
        await #expect(throws: CardReadError.malformedCertificate) {
            try await JPKIReader(transport: transport).readAuthenticationCertificate()
        }
        #expect(transport.sent.count == 3)
    }

    @Test func anEmptyChunkStopsInsteadOfLoopingForever() async {
        let transport = ScriptedTransport([ok(), ok(), ok(Data([0x30, 0x82, 0x01, 0x00])), ok(Data())])
        await #expect(throws: CardReadError.malformedCertificate) {
            try await JPKIReader(transport: transport).readAuthenticationCertificate()
        }
    }

    @Test func aLostConnectionMidReadSurfacesAsConnectionLost() async {
        let transport = ScriptedTransport([ok(), ok(), ok(Data([0x30, 0x82, 0x01, 0x00])), .failure(.connectionLost)])
        await #expect(throws: CardReadError.connectionLost) {
            try await JPKIReader(transport: transport).readAuthenticationCertificate()
        }
    }
}

@Suite struct CertificateTests {
    @Test func readsTheIssuerAndValidityAndDropsEverythingElse() throws {
        let notBefore = date("2024-04-01T00:00:00Z")
        let notAfter = date("2029-03-31T14:59:59Z")
        let certificate = SyntheticCertificate.make(issuerUnit: "Test Authority", notBefore: notBefore, notAfter: notAfter)

        let summary = try CertificateSummary(certificate: certificate)

        #expect(summary == CertificateSummary(issuer: "Test Authority / ICReadKit", notBefore: notBefore, notAfter: notAfter))
    }

    @Test func expiredIsAResultNotAnError() throws {
        let summary = try CertificateSummary(certificate: SyntheticCertificate.make(card: .expired, now: date("2026-11-11T00:00:00Z")))
        #expect(summary.validity(at: date("2026-11-11T00:00:00Z")) == .expired)
        #expect(summary.validity(at: summary.notBefore - 1) == .notYetValid)
        #expect(summary.validity(at: summary.notBefore) == .valid)
    }

    @Test func utcTimeYearsFollowRFC5280() throws {
        let y49 = DER.Element(tag: DER.Tag.utcTime, value: Data("491231235959Z".utf8))
        let y50 = DER.Element(tag: DER.Tag.utcTime, value: Data("500101000000Z".utf8))
        #expect(try DER.date(from: y49) == date("2049-12-31T23:59:59Z"))
        #expect(try DER.date(from: y50) == date("1950-01-01T00:00:00Z"))
    }

    @Test func impossibleDatesAreRejected() {
        let month13 = DER.Element(tag: DER.Tag.generalizedTime, value: Data("20261301000000Z".utf8))
        let local = DER.Element(tag: DER.Tag.generalizedTime, value: Data("20261101000000".utf8))
        #expect(throws: DER.MalformedError.self) { try DER.date(from: month13) }
        #expect(throws: DER.MalformedError.self) { try DER.date(from: local) }
    }

    @Test func truncatedCertificatesAreMalformed() {
        let certificate = SyntheticCertificate.make(card: .valid, now: Date())
        #expect(throws: CardReadError.malformedCertificate) { try CertificateSummary(certificate: certificate.prefix(40)) }
        #expect(throws: CardReadError.malformedCertificate) { try CertificateSummary(certificate: Data()) }
    }
}

@Suite struct AvailabilityTests {
    let configured: [String: Any] = [
        "NFCReaderUsageDescription": "証明書の有効期限を確かめるために使います",
        "com.apple.developer.nfc.readersession.iso7816.select-identifiers": ["D392F000260100000001"],
    ]

    @Test func aConfiguredAppOnAReaderIsAvailable() {
        #expect(Availability.check(infoDictionary: configured, readingSupported: true) == .available)
    }

    @Test func configurationMistakesAreReportedBeforeTheDeviceCheck() {
        var noUsage = configured
        noUsage["NFCReaderUsageDescription"] = "  "
        var noIdentifier = configured
        noIdentifier["com.apple.developer.nfc.readersession.iso7816.select-identifiers"] = ["A0000002471001"]

        #expect(Availability.check(infoDictionary: noUsage, readingSupported: false) == .unavailable(.missingUsageDescription))
        #expect(Availability.check(infoDictionary: noIdentifier, readingSupported: true) == .unavailable(.missingApplicationIdentifier))
        #expect(Availability.check(infoDictionary: nil, readingSupported: true) == .unavailable(.missingUsageDescription))
    }

    @Test func lowercaseIdentifiersCount() {
        var lower = configured
        lower["com.apple.developer.nfc.readersession.iso7816.select-identifiers"] = ["d392f000260100000001"]
        #expect(Availability.check(infoDictionary: lower, readingSupported: true) == .available)
    }

    @Test func theSimulatorIsUnsupportedOnceConfigured() {
        #expect(Availability.check(infoDictionary: configured, readingSupported: false) == .unavailable(.readingUnsupported))
    }
}

@Suite struct DemoTests {
    @Test func theDemoCardsCoverTheResultsAHostAppMustHandle() async throws {
        let valid = try await CardReader(source: .demo(.valid)).readCertificateSummary()
        #expect(valid.validity() == .valid)
        #expect(valid.issuer.contains(SyntheticCertificate.issuerUnit))

        let expired = try await CardReader(source: .demo(.expired)).readCertificateSummary()
        #expect(expired.validity() == .expired)

        await #expect(throws: CardReadError.unsupportedCard) {
            try await CardReader(source: .demo(.otherCard)).readCertificateSummary()
        }
        await #expect(throws: CardReadError.connectionLost) {
            try await CardReader(source: .demo(.connectionLost)).readCertificateSummary()
        }
    }

    @Test func aDemoSourceIsAlwaysAvailable() {
        #expect(CardReader(source: .demo(.valid)).availability(bundle: Bundle(for: ScriptedTransport.self)) == .available)
    }
}

#if canImport(CoreNFC)
import CoreNFC

@Suite struct NFCErrorMappingTests {
    @Test func systemErrorsBecomeReasonsAHostAppCanActOn() {
        #expect(NFCCertificateSession.map(NFCReaderError(.readerSessionInvalidationErrorUserCanceled)) == .cancelled)
        #expect(NFCCertificateSession.map(NFCReaderError(.readerSessionInvalidationErrorSessionTimeout)) == .timeout)
        #expect(NFCCertificateSession.map(NFCReaderError(.readerTransceiveErrorTagConnectionLost)) == .connectionLost)
        #expect(NFCCertificateSession.map(NFCReaderError(.readerErrorUnsupportedFeature)) == .unavailable(.readingUnsupported))
    }

    @Test func unmappedErrorsKeepTheirCodeInsteadOfCrashing() {
        let code = NFCReaderError.Code.readerErrorSecurityViolation
        #expect(NFCCertificateSession.map(NFCReaderError(code)) == .system(code: code.rawValue))
        #expect(NFCCertificateSession.map(CardReadError.unsupportedCard) == .unsupportedCard)
    }
}
#endif

/// Collects events from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CardReadEvent] = []
    var events: [CardReadEvent] { lock.withLock { stored } }
    func record(_ event: CardReadEvent) { lock.withLock { stored.append(event) } }

    /// The events with durations zeroed, so tests can compare them exactly.
    var steps: [CardReadEvent] {
        events.map {
            if case .finished(let outcome, _) = $0 { return .finished(outcome, duration: .zero) }
            return $0
        }
    }
}

@Suite struct EventTests {
    @Test func aSuccessfulReadWalksTheWholeFunnel() async throws {
        let log = EventLog()
        _ = try await CardReader(source: .demo(.valid), onEvent: log.record).readCertificateSummary()
        #expect(log.steps == [.started(demo: true), .cardDetected(attempt: 1), .finished(.read(.valid), duration: .zero)])
    }

    @Test func anExpiredCardIsStillARead() async throws {
        let log = EventLog()
        _ = try await CardReader(source: .demo(.expired), onEvent: log.record).readCertificateSummary()
        #expect(log.steps.last == .finished(.read(.expired), duration: .zero))
    }

    @Test func failuresCarryTheReasonButNoCardData() async {
        let log = EventLog()
        _ = try? await CardReader(source: .demo(.connectionLost), onEvent: log.record).readCertificateSummary()
        #expect(log.steps == [.started(demo: true), .cardDetected(attempt: 1), .finished(.failed(.connectionLost), duration: .zero)])
    }

    @Test func aDurationIsMeasuredFromStart() async throws {
        let log = EventLog()
        _ = try await CardReader(source: .demo(.valid), onEvent: log.record).readCertificateSummary()
        guard case .finished(_, let duration) = log.events.last else { Issue.record("no finished event"); return }
        #expect(duration >= .zero && duration < .seconds(5))
    }

    @Test func theOldInitializerStillWorksWithoutEvents() async throws {
        _ = try await CardReader(source: .demo(.valid)).readCertificateSummary()
    }
}

/// Answers Wallet requests from a script and records what it was asked.
final class ScriptedAuthorizer: IdentityAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    let canAnswer: Bool
    let answer: Result<Data, any Error>
    private(set) var asked: [WalletIDRequestSpec] = []

    init(canAnswer: Bool = true, answer: Result<Data, any Error> = .success(Data([0xA1, 0x01]))) {
        self.canAnswer = canAnswer
        self.answer = answer
    }

    func canRequest(_ spec: WalletIDRequestSpec) async -> Bool { canAnswer }

    func request(_ spec: WalletIDRequestSpec) async throws -> Data {
        lock.withLock { asked.append(spec) }
        return try answer.get()
    }
}

@Suite struct WalletIDTests {
    let nonce = Data(repeating: 7, count: 32)

    @Test func aRequestCarriesTheServerNonceAndReturnsTheEncryptedResponseUnopened() async throws {
        let authorizer = ScriptedAuthorizer()
        let reader = WalletIDReader(merchantIdentifier: "merchant.example", authorizer: authorizer)

        let presentation = try await reader.requestPresentation(of: [.name, .ageAtLeast(18)], nonce: nonce)

        #expect(presentation == WalletIDPresentation(encryptedData: Data([0xA1, 0x01]), nonce: nonce))
        #expect(authorizer.asked.first?.merchantIdentifier == "merchant.example")
        #expect(authorizer.asked.first?.nonce == nonce)
        #expect(authorizer.asked.first?.storeForDays == nil)
    }

    @Test func badNoncesAndEmptyRequestsStopBeforeWalletOpens() async {
        let authorizer = ScriptedAuthorizer()
        let reader = WalletIDReader(merchantIdentifier: "merchant.example", authorizer: authorizer)
        await #expect(throws: WalletIDError.invalidNonce) { try await reader.requestPresentation(of: [.name], nonce: Data(count: 8)) }
        await #expect(throws: WalletIDError.invalidNonce) { try await reader.requestPresentation(of: [.name], nonce: Data(count: 65)) }
        await #expect(throws: WalletIDError.invalidRequest) { try await reader.requestPresentation(of: [], nonce: nonce) }
        await #expect(throws: WalletIDError.invalidRequest) { try await reader.requestPresentation(of: [.name], nonce: nonce, storeForDays: 0) }
        #expect(authorizer.asked.isEmpty)
    }

    @Test func availabilityFollowsWallet() async {
        #expect(await WalletIDReader(merchantIdentifier: "m", authorizer: ScriptedAuthorizer()).availability(for: [.name]) == .available)
        #expect(await WalletIDReader(merchantIdentifier: "m", authorizer: ScriptedAuthorizer(canAnswer: false)).availability(for: [.name])
            == .unavailable(.cannotRequest))
        #expect(await WalletIDReader(merchantIdentifier: "m", authorizer: ScriptedAuthorizer()).availability(for: []) == .unavailable(.cannotRequest))
    }

    @Test func passKitErrorsBecomeReasonsAHostAppCanActOn() {
        let cases: [(Int, WalletIDError)] = [
            (1, .unavailable(.cannotRequest)), (2, .cancelled), (3, .networkUnavailable), (4, .invalidRequest),
            (5, .busy), (6, .invalidNonce), (7, .invalidRequest), (8, .regionNotSupported), (0, .system(code: 0)),
        ]
        for (code, expected) in cases {
            #expect(WalletIDReader.map(NSError(domain: PKIdentityErrorDomain, code: code)) == expected)
        }
        #expect(WalletIDReader.map(NSError(domain: "Other", code: 9)) == .system(code: 9))
    }

    @Test func thePassKitRequestAsksTheJapaneseNationalIDCardForOnlyWhatWasNamed() throws {
        let spec = try WalletIDRequestSpec(elements: [.name, .ageAtLeast(20)], storeForDays: nil, nonce: nonce, merchantIdentifier: "merchant.example")
        let request = PassKitIdentityAuthorizer.request(for: spec)
        let descriptor = try #require(request.descriptor as? PKIdentityNationalIDCardDescriptor)

        #expect(descriptor.region == Locale.Region("JP"))
        #expect(descriptor.elements.count == 3)  // given name, family name, age threshold
        #expect(request.nonce == nonce)
        #expect(request.merchantIdentifier == "merchant.example")
        // PassKit makes a new element object per access, so look intents up with the descriptor's own elements.
        #expect(descriptor.elements.allSatisfy { String(describing: descriptor.intentToStore(element: $0)!) == String(describing: PKIdentityIntentToStore.willNotStore) })
    }

    @Test func storingIsDeclaredWhenTheServiceKeepsTheData() throws {
        let spec = try WalletIDRequestSpec(elements: [.address], storeForDays: 30, nonce: nonce, merchantIdentifier: "m")
        let descriptor = PassKitIdentityAuthorizer.descriptor(for: spec)
        let address = try #require(descriptor.elements.first)
        #expect(String(describing: descriptor.intentToStore(element: address)!) == String(describing: PKIdentityIntentToStore.mayStore(days: 30)))
    }
}

@Suite struct VerificationHandOffTests {
    @Test func theVerifiableReadReturnsTheExactBytesTheSummaryCameFrom() async throws {
        let read = try await CardReader(source: .demo(.valid)).readCertificateForVerification()
        #expect(try CertificateSummary(certificate: read.der) == read.summary)
        #expect(read.der.first == 0x30)
    }

    @Test func bothReadsReportTheSameFunnel() async throws {
        let log = EventLog()
        _ = try await CardReader(source: .demo(.expired), onEvent: log.record).readCertificateForVerification()
        #expect(log.steps == [.started(demo: true), .cardDetected(attempt: 1), .finished(.read(.expired), duration: .zero)])
    }
}
