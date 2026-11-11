import Foundation

/// The public key (JPKI) application on a My Number card.
enum JPKI {
    /// The application identifier of the JPKI application.
    static let applicationIdentifier = Data([0xD3, 0x92, 0xF0, 0x00, 0x26, 0x01, 0x00, 0x00, 0x00, 0x01])
    /// The DER certificate for user authentication. Reading it needs no PIN, and
    /// it carries no name, address or birth date.
    static let authenticationCertificateFile: UInt16 = 0x000A
}

/// Reads the authentication certificate over any transport.
struct JPKIReader: Sendable {
    let transport: any CardTransport
    /// The most bytes one READ BINARY asks for.
    var chunkLength = 256

    func readAuthenticationCertificate() async throws(CardReadError) -> Data {
        try await expectSuccess(.selectApplication(JPKI.applicationIdentifier))
        try await expectSuccess(.selectFile(JPKI.authenticationCertificateFile))

        // The first four bytes are the DER header, which says how long the whole certificate is.
        let header = try await read(offset: 0, length: 4)
        guard let total = DER.encodedLength(ofHeader: header), total >= header.count else {
            throw .malformedCertificate
        }
        guard total <= 0x7FFF else { throw .malformedCertificate }

        var certificate = header
        while certificate.count < total {
            let length = min(chunkLength, total - certificate.count)
            let part = try await read(offset: certificate.count, length: length)
            guard !part.isEmpty else { throw .malformedCertificate }
            certificate.append(part)
        }
        return certificate.prefix(total)
    }

    private func expectSuccess(_ command: CommandAPDU) async throws(CardReadError) {
        let response = try await transport.transmit(command)
        guard response.isSuccess else { throw Self.error(for: response) }
    }

    private func read(offset: Int, length: Int) async throws(CardReadError) -> Data {
        let response = try await transport.transmit(.readBinary(offset: offset, length: length))
        guard response.isSuccess else { throw Self.error(for: response) }
        return response.data
    }

    static func error(for response: ResponseAPDU) -> CardReadError {
        switch response.statusWord {
        case 0x6A82, 0x6A86, 0x6D00: .unsupportedCard  // not found, wrong P1-P2, INS not supported
        default: .cardRejected(statusWord: response.statusWord)
        }
    }
}
