package com.bestcatscience.icreadkit;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;

/** Reads the user authentication certificate from the JPKI application over any transport. */
final class JpkiReader {
    /** The application identifier of the JPKI application on a My Number card. */
    static final byte[] APPLICATION_ID = {
        (byte) 0xD3, (byte) 0x92, (byte) 0xF0, 0x00, 0x26, 0x01, 0x00, 0x00, 0x00, 0x01
    };
    /** The DER certificate for user authentication. Reading it needs no PIN. */
    static final int AUTHENTICATION_CERTIFICATE_FILE = 0x000A;

    private final CardTransport transport;
    private final int chunkLength;

    JpkiReader(CardTransport transport) {
        this(transport, 256);
    }

    JpkiReader(CardTransport transport, int chunkLength) {
        this.transport = transport;
        this.chunkLength = chunkLength;
    }

    byte[] readAuthenticationCertificate() throws CardReadException {
        expectSuccess(CommandApdu.selectApplication(APPLICATION_ID));
        expectSuccess(CommandApdu.selectFile(AUTHENTICATION_CERTIFICATE_FILE));

        // The first four bytes are the DER header, which says how long the whole certificate is.
        byte[] header = read(0, 4);
        int total = Der.encodedLength(header);
        if (total < header.length || total > 0x7FFF) {
            throw new CardReadException(CardReadException.Reason.MALFORMED_CERTIFICATE);
        }
        ByteArrayOutputStream certificate = new ByteArrayOutputStream(total);
        certificate.write(header, 0, header.length);
        while (certificate.size() < total) {
            byte[] part = read(certificate.size(), Math.min(chunkLength, total - certificate.size()));
            if (part.length == 0) throw new CardReadException(CardReadException.Reason.MALFORMED_CERTIFICATE);
            certificate.write(part, 0, part.length);
        }
        return Arrays.copyOf(certificate.toByteArray(), total);
    }

    private void expectSuccess(CommandApdu command) throws CardReadException {
        ResponseApdu response = transport.transmit(command);
        if (!response.isSuccess()) throw error(response);
    }

    private byte[] read(int offset, int length) throws CardReadException {
        ResponseApdu response = transport.transmit(CommandApdu.readBinary(offset, length));
        if (!response.isSuccess()) throw error(response);
        return response.data;
    }

    static CardReadException error(ResponseApdu response) {
        switch (response.statusWord) {
            case 0x6A82: // file or application not found
            case 0x6A86: // wrong P1-P2
            case 0x6D00: // instruction not supported
                return new CardReadException(CardReadException.Reason.UNSUPPORTED_CARD);
            default:
                return new CardReadException(CardReadException.Reason.CARD_REJECTED, response.statusWord);
        }
    }
}
