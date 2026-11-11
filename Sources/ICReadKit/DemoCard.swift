import Foundation

/// A card the kit can pretend to read, so a host app can build and test its screens on the simulator.
///
/// The certificate is synthetic: made up here, with no real person's data.
public enum DemoCard: String, CaseIterable, Sendable {
    /// A card whose certificate is valid today.
    case valid
    /// A card whose certificate expired yesterday.
    case expired
    /// A card with no public key application, such as a transit card.
    case otherCard = "other-card"
    /// A card that moves away in the middle of the read.
    case connectionLost = "connection-lost"
}

/// Answers SELECT and READ BINARY the way a card would.
struct DemoTransport: CardTransport {
    let card: DemoCard
    let now: Date

    func transmit(_ command: CommandAPDU) async throws(CardReadError) -> ResponseAPDU {
        let ok = { (data: Data) in ResponseAPDU(data: data, sw1: 0x90, sw2: 0x00) }
        switch (command.ins, card) {
        case (CommandAPDU.Instruction.select, .otherCard):
            return ResponseAPDU(data: Data(), sw1: 0x6A, sw2: 0x82)
        case (CommandAPDU.Instruction.select, _):
            return ok(Data())
        case (CommandAPDU.Instruction.readBinary, .connectionLost) where command.p1 != 0 || command.p2 != 0:
            throw .connectionLost
        case (CommandAPDU.Instruction.readBinary, _):
            let certificate = SyntheticCertificate.make(card: card, now: now)
            let offset = Int(command.p1) << 8 | Int(command.p2)
            guard offset < certificate.count else { return ResponseAPDU(data: Data(), sw1: 0x6B, sw2: 0x00) }
            let length = command.expectedLength ?? 256
            return ok(certificate.subdata(in: offset..<min(certificate.count, offset + length)))
        default:
            return ResponseAPDU(data: Data(), sw1: 0x6D, sw2: 0x00)
        }
    }
}

/// Builds a structurally valid X.509 certificate with made-up content. The signature is not real.
enum SyntheticCertificate {
    static let issuerUnit = "ICReadKit Demo Authority"

    static func make(card: DemoCard, now: Date, day: TimeInterval = 86_400) -> Data {
        let notBefore: Date
        let notAfter: Date
        if card == .expired {
            notBefore = now - 5 * 365 * day
            notAfter = now - day
        } else {
            notBefore = now - 365 * day
            notAfter = now + 4 * 365 * day
        }
        return make(issuerUnit: issuerUnit, notBefore: notBefore, notAfter: notAfter)
    }

    static func make(issuerUnit: String, notBefore: Date, notAfter: Date) -> Data {
        let algorithm = sequence(tlv(DER.Tag.objectIdentifier, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])) + tlv(0x05, Data()))
        let issuer = sequence(
            tlv(DER.Tag.set, sequence(tlv(DER.Tag.objectIdentifier, Data([0x55, 0x04, 0x06])) + tlv(DER.Tag.printableString, Data("JP".utf8))))
                + tlv(DER.Tag.set, sequence(tlv(DER.Tag.objectIdentifier, Data([0x55, 0x04, 0x0A])) + tlv(DER.Tag.utf8String, Data("ICReadKit".utf8))))
                + tlv(DER.Tag.set, sequence(tlv(DER.Tag.objectIdentifier, Data([0x55, 0x04, 0x0B])) + tlv(DER.Tag.utf8String, Data(issuerUnit.utf8))))
        )
        let validity = sequence(time(notBefore) + time(notAfter))
        let subject = sequence(tlv(DER.Tag.set, sequence(tlv(DER.Tag.objectIdentifier, Data([0x55, 0x04, 0x06])) + tlv(DER.Tag.printableString, Data("JP".utf8)))))
        let publicKey = sequence(algorithm + tlv(0x03, Data([0x00]) + Data(repeating: 0xAB, count: 270)))
        let tbs = sequence(
            tlv(DER.Tag.explicitVersion, tlv(DER.Tag.integer, Data([0x02])))
                + tlv(DER.Tag.integer, Data([0x01]))
                + algorithm + issuer + validity + subject + publicKey
        )
        return sequence(tbs + algorithm + tlv(0x03, Data([0x00]) + Data(repeating: 0xCD, count: 256)))
    }

    private static func time(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%04d%02d%02d%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return tlv(DER.Tag.generalizedTime, Data(text.utf8))
    }

    private static func sequence(_ content: Data) -> Data { tlv(DER.Tag.sequence, content) }

    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        switch value.count {
        case ..<0x80: out.append(UInt8(value.count))
        case ..<0x100: out.append(contentsOf: [0x81, UInt8(value.count)])
        default: out.append(contentsOf: [0x82, UInt8(value.count >> 8), UInt8(value.count & 0xFF)])
        }
        return out + value
    }
}
