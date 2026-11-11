import Foundation

/// An ISO/IEC 7816-4 command in the short form.
///
/// The kit can only build the two commands it needs: SELECT and READ BINARY.
/// There is deliberately no way to build VERIFY or any other command that
/// presents a PIN, because a wrong PIN counts toward locking the card.
struct CommandAPDU: Equatable, Sendable {
    let cla: UInt8
    let ins: UInt8
    let p1: UInt8
    let p2: UInt8
    let data: Data
    /// The expected response length. 256 is sent as 0x00; nil sends no Le.
    let expectedLength: Int?

    private init(ins: UInt8, p1: UInt8, p2: UInt8, data: Data = Data(), expectedLength: Int? = nil) {
        self.cla = 0x00
        self.ins = ins
        self.p1 = p1
        self.p2 = p2
        self.data = data
        self.expectedLength = expectedLength
    }

    /// The bytes as they go over the air.
    var bytes: Data {
        var bytes = Data([cla, ins, p1, p2])
        if !data.isEmpty {
            bytes.append(UInt8(data.count))
            bytes.append(data)
        }
        if let expectedLength {
            bytes.append(expectedLength == 256 ? 0x00 : UInt8(expectedLength))
        }
        return bytes
    }

    /// SELECT an application by its AID, asking for no FCI in the response.
    static func selectApplication(_ identifier: Data) -> CommandAPDU {
        precondition((1...16).contains(identifier.count), "An AID is 1 to 16 bytes")
        return CommandAPDU(ins: Instruction.select, p1: 0x04, p2: 0x0C, data: identifier)
    }

    /// SELECT an elementary file inside the current application.
    static func selectFile(_ identifier: UInt16) -> CommandAPDU {
        CommandAPDU(ins: Instruction.select, p1: 0x02, p2: 0x0C, data: Data([UInt8(identifier >> 8), UInt8(identifier & 0xFF)]))
    }

    /// READ BINARY from the selected file. The offset is 15 bits in P1-P2.
    static func readBinary(offset: Int, length: Int) -> CommandAPDU {
        precondition((0...0x7FFF).contains(offset), "READ BINARY offsets are 15 bits")
        precondition((1...256).contains(length), "A short READ BINARY returns 1 to 256 bytes")
        return CommandAPDU(ins: Instruction.readBinary, p1: UInt8(offset >> 8), p2: UInt8(offset & 0xFF), expectedLength: length)
    }

    enum Instruction {
        static let select: UInt8 = 0xA4
        static let readBinary: UInt8 = 0xB0
        /// Everything the kit is allowed to send. A transport refuses the rest.
        static let allowed: Set<UInt8> = [select, readBinary]
    }
}

/// A card's response: the data and the two status bytes.
struct ResponseAPDU: Equatable, Sendable {
    let data: Data
    let sw1: UInt8
    let sw2: UInt8

    var statusWord: UInt16 { UInt16(sw1) << 8 | UInt16(sw2) }
    var isSuccess: Bool { sw1 == 0x90 && sw2 == 0x00 }
}
