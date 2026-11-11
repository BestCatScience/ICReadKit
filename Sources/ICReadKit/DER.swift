import Foundation

/// The small part of DER the kit needs: walking TLVs, reading names and times.
enum DER {
    enum Tag {
        static let integer: UInt8 = 0x02
        static let objectIdentifier: UInt8 = 0x06
        static let utf8String: UInt8 = 0x0C
        static let printableString: UInt8 = 0x13
        static let utcTime: UInt8 = 0x17
        static let generalizedTime: UInt8 = 0x18
        static let sequence: UInt8 = 0x30
        static let set: UInt8 = 0x31
        static let explicitVersion: UInt8 = 0xA0
    }

    struct Element {
        let tag: UInt8
        let value: Data
    }

    struct MalformedError: Error {}

    /// The total length of a DER element whose first bytes are `header`, or nil if the header is not a SEQUENCE header.
    static func encodedLength(ofHeader header: Data) -> Int? {
        let bytes = [UInt8](header)
        guard bytes.count >= 2, bytes[0] == Tag.sequence else { return nil }
        let first = Int(bytes[1])
        if first < 0x80 { return 2 + first }
        let count = first & 0x7F
        guard (1...2).contains(count), bytes.count >= 2 + count else { return nil }
        let length = bytes[2..<(2 + count)].reduce(0) { $0 << 8 | Int($1) }
        return 2 + count + length
    }

    /// Reads consecutive TLVs from `data`.
    struct Reader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        var isAtEnd: Bool { index >= bytes.count }

        func peekTag() -> UInt8? { isAtEnd ? nil : bytes[index] }

        mutating func next() throws(MalformedError) -> Element {
            guard index + 2 <= bytes.count else { throw MalformedError() }
            let tag = bytes[index]
            var cursor = index + 1
            let first = Int(bytes[cursor])
            cursor += 1
            var length = first
            if first >= 0x80 {
                let count = first & 0x7F
                guard (1...3).contains(count), cursor + count <= bytes.count else { throw MalformedError() }
                length = bytes[cursor..<(cursor + count)].reduce(0) { $0 << 8 | Int($1) }
                cursor += count
            }
            guard cursor + length <= bytes.count else { throw MalformedError() }
            let value = Data(bytes[cursor..<(cursor + length)])
            index = cursor + length
            return Element(tag: tag, value: value)
        }

        mutating func next(expecting tag: UInt8) throws(MalformedError) -> Element {
            let element = try next()
            guard element.tag == tag else { throw MalformedError() }
            return element
        }
    }

    /// Parses UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ) in UTC.
    static func date(from element: Element) throws(MalformedError) -> Date {
        guard let text = String(data: element.value, encoding: .ascii), text.hasSuffix("Z") else { throw MalformedError() }
        let digits = Array(text.dropLast())
        guard digits.allSatisfy(\.isNumber) else { throw MalformedError() }
        let numbers = digits.compactMap(\.wholeNumberValue)
        func value(_ range: Range<Int>) -> Int { numbers[range].reduce(0) { $0 * 10 + $1 } }

        var components = DateComponents()
        let rest: Int
        switch (element.tag, numbers.count) {
        case (Tag.utcTime, 12):
            let year = value(0..<2)
            components.year = year < 50 ? 2000 + year : 1900 + year  // RFC 5280 4.1.2.5.1
            rest = 2
        case (Tag.generalizedTime, 14):
            components.year = value(0..<4)
            rest = 4
        default:
            throw MalformedError()
        }
        components.month = value(rest..<(rest + 2))
        components.day = value((rest + 2)..<(rest + 4))
        components.hour = value((rest + 4)..<(rest + 6))
        components.minute = value((rest + 6)..<(rest + 8))
        components.second = value((rest + 8)..<(rest + 10))
        guard (1...12).contains(components.month!), (1...31).contains(components.day!),
              (0...23).contains(components.hour!), (0...59).contains(components.minute!),
              (0...59).contains(components.second!)
        else { throw MalformedError() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { throw MalformedError() }
        return date
    }
}
