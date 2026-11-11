package com.bestcatscience.icreadkit;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Arrays;

/** Answers SELECT and READ BINARY the way a card would. */
final class DemoTransport implements CardTransport {
    private final DemoCard card;
    private final Instant now;

    DemoTransport(DemoCard card, Instant now) {
        this.card = card;
        this.now = now;
    }

    @Override
    public ResponseApdu transmit(CommandApdu command) throws CardReadException {
        if (command.ins == CommandApdu.INS_SELECT) {
            return card == DemoCard.OTHER_CARD ? new ResponseApdu(new byte[0], 0x6A82) : new ResponseApdu(new byte[0], 0x9000);
        }
        if (command.ins == CommandApdu.INS_READ_BINARY) {
            int offset = (command.p1 & 0xFF) << 8 | (command.p2 & 0xFF);
            if (card == DemoCard.CONNECTION_LOST && offset > 0) {
                throw new CardReadException(CardReadException.Reason.CONNECTION_LOST);
            }
            byte[] certificate = SyntheticCertificate.make(card, now);
            if (offset >= certificate.length) return new ResponseApdu(new byte[0], 0x6B00);
            int end = Math.min(certificate.length, offset + command.expectedLength);
            return new ResponseApdu(Arrays.copyOfRange(certificate, offset, end), 0x9000);
        }
        return new ResponseApdu(new byte[0], 0x6D00);
    }
}

/** Builds a structurally valid X.509 certificate with made-up content. The signature is not real. */
final class SyntheticCertificate {
    static final String ISSUER_UNIT = "ICReadKit Demo Authority";
    private static final Duration DAY = Duration.ofDays(1);

    private SyntheticCertificate() {}

    static byte[] make(DemoCard card, Instant now) {
        if (card == DemoCard.EXPIRED) {
            return make(ISSUER_UNIT, now.minus(DAY.multipliedBy(5 * 365)), now.minus(DAY));
        }
        return make(ISSUER_UNIT, now.minus(DAY.multipliedBy(365)), now.plus(DAY.multipliedBy(4 * 365)));
    }

    static byte[] make(String issuerUnit, Instant notBefore, Instant notAfter) {
        byte[] algorithm = sequence(concat(tlv(Der.OBJECT_IDENTIFIER, new byte[] {0x2A, (byte) 0x86, 0x48, (byte) 0x86, (byte) 0xF7, 0x0D, 0x01, 0x01, 0x0B}), tlv(0x05, new byte[0])));
        byte[] issuer = sequence(concat(
            attribute(new byte[] {0x55, 0x04, 0x06}, Der.PRINTABLE_STRING, "JP"),
            attribute(new byte[] {0x55, 0x04, 0x0A}, Der.UTF8_STRING, "ICReadKit"),
            attribute(new byte[] {0x55, 0x04, 0x0B}, Der.UTF8_STRING, issuerUnit)));
        byte[] validity = sequence(concat(time(notBefore), time(notAfter)));
        byte[] subject = sequence(attribute(new byte[] {0x55, 0x04, 0x06}, Der.PRINTABLE_STRING, "JP"));
        byte[] key = new byte[271];
        Arrays.fill(key, (byte) 0xAB);
        key[0] = 0x00;
        byte[] publicKey = sequence(concat(algorithm, tlv(0x03, key)));
        byte[] tbs = sequence(concat(
            tlv(Der.EXPLICIT_VERSION, tlv(Der.INTEGER, new byte[] {0x02})),
            tlv(Der.INTEGER, new byte[] {0x01}),
            algorithm, issuer, validity, subject, publicKey));
        byte[] signature = new byte[257];
        Arrays.fill(signature, (byte) 0xCD);
        signature[0] = 0x00;
        return sequence(concat(tbs, algorithm, tlv(0x03, signature)));
    }

    private static byte[] attribute(byte[] type, int tag, String value) {
        return tlv(Der.SET, sequence(concat(tlv(Der.OBJECT_IDENTIFIER, type), tlv(tag, value.getBytes(StandardCharsets.UTF_8)))));
    }

    private static byte[] time(Instant instant) {
        String text = DateTimeFormatter.ofPattern("yyyyMMddHHmmss'Z'").withZone(ZoneOffset.UTC).format(instant);
        return tlv(Der.GENERALIZED_TIME, text.getBytes(StandardCharsets.US_ASCII));
    }

    private static byte[] sequence(byte[] content) {
        return tlv(Der.SEQUENCE, content);
    }

    static byte[] tlv(int tag, byte[] value) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(tag);
        if (value.length < 0x80) {
            out.write(value.length);
        } else if (value.length < 0x100) {
            out.write(0x81);
            out.write(value.length);
        } else {
            out.write(0x82);
            out.write(value.length >> 8);
            out.write(value.length & 0xFF);
        }
        out.write(value, 0, value.length);
        return out.toByteArray();
    }

    private static byte[] concat(byte[]... parts) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] part : parts) out.write(part, 0, part.length);
        return out.toByteArray();
    }
}
