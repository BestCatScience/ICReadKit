import Foundation
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
