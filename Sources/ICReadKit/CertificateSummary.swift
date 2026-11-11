import Foundation

/// What the kit tells the host app about the certificate: who issued it and when it is valid.
///
/// It deliberately leaves out the serial number, the subject and the public key.
/// The raw certificate bytes never leave the kit.
public struct CertificateSummary: Equatable, Sendable {
    /// The issuer's common name, or its organizational units and organization when it has no common name.
    public let issuer: String
    public let notBefore: Date
    public let notAfter: Date

    public init(issuer: String, notBefore: Date, notAfter: Date) {
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
    }

    public enum Validity: Equatable, Sendable {
        case valid
        case expired
        case notYetValid
    }

    /// An expired certificate is a normal result, not an error: the host app decides what to tell the person.
    public func validity(at date: Date = Date()) -> Validity {
        if date < notBefore { return .notYetValid }
        if date > notAfter { return .expired }
        return .valid
    }
}

extension CertificateSummary {
    private static let commonName = Data([0x55, 0x04, 0x03])
    private static let organization = Data([0x55, 0x04, 0x0A])
    private static let organizationalUnit = Data([0x55, 0x04, 0x0B])

    /// Reads the issuer and the validity period from an X.509 certificate in DER.
    init(certificate: Data) throws(CardReadError) {
        do {
            var outer = DER.Reader(certificate)
            let certificateSequence = try outer.next(expecting: DER.Tag.sequence)
            var certificateFields = DER.Reader(certificateSequence.value)
            let tbs = try certificateFields.next(expecting: DER.Tag.sequence)
            var fields = DER.Reader(tbs.value)
            if fields.peekTag() == DER.Tag.explicitVersion { _ = try fields.next() }
            _ = try fields.next(expecting: DER.Tag.integer)  // serial number, not kept
            _ = try fields.next(expecting: DER.Tag.sequence)  // signature algorithm
            let issuerName = try fields.next(expecting: DER.Tag.sequence)
            let validity = try fields.next(expecting: DER.Tag.sequence)

            var times = DER.Reader(validity.value)
            let notBefore = try DER.date(from: times.next())
            let notAfter = try DER.date(from: times.next())
            guard notBefore <= notAfter else { throw DER.MalformedError() }

            self.init(issuer: try Self.displayName(of: issuerName.value), notBefore: notBefore, notAfter: notAfter)
        } catch {
            throw .malformedCertificate
        }
    }

    private static func displayName(of name: Data) throws(DER.MalformedError) -> String {
        var commonNames: [String] = []
        var units: [String] = []
        var organizations: [String] = []
        var relativeNames = DER.Reader(name)
        while !relativeNames.isAtEnd {
            var attributes = DER.Reader(try relativeNames.next(expecting: DER.Tag.set).value)
            while !attributes.isAtEnd {
                var pair = DER.Reader(try attributes.next(expecting: DER.Tag.sequence).value)
                let type = try pair.next(expecting: DER.Tag.objectIdentifier).value
                let value = try pair.next()
                guard [DER.Tag.utf8String, DER.Tag.printableString].contains(value.tag),
                      let text = String(data: value.value, encoding: .utf8)
                else { continue }
                switch type {
                case commonName: commonNames.append(text)
                case organizationalUnit: units.append(text)
                case organization: organizations.append(text)
                default: break
                }
            }
        }
        if let name = commonNames.first { return name }
        return (units + organizations).joined(separator: " / ")
    }
}

/// The certificate as read from the card, for verification on the host app's server.
///
/// The authentication certificate carries no name, address or birth date, but its serial
/// number identifies the card. Send it only to your own server over TLS, and do not log it.
public struct VerifiableCertificate: Equatable, Sendable {
    /// The DER bytes, to be base64-encoded into the server's `certificate` field.
    public let der: Data
    /// The same issuer and validity ``CardReader/readCertificateSummary()`` returns.
    public let summary: CertificateSummary
}
