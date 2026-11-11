package com.bestcatscience.icreadkit;

import java.nio.charset.StandardCharsets;
import java.time.DateTimeException;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Arrays;

/** The small part of DER the kit needs: walking TLVs, reading names and times. */
final class Der {
    static final int INTEGER = 0x02;
    static final int OBJECT_IDENTIFIER = 0x06;
    static final int UTF8_STRING = 0x0C;
    static final int PRINTABLE_STRING = 0x13;
    static final int UTC_TIME = 0x17;
    static final int GENERALIZED_TIME = 0x18;
    static final int SEQUENCE = 0x30;
    static final int SET = 0x31;
    static final int EXPLICIT_VERSION = 0xA0;

    static final class Malformed extends Exception {}

    static final class Element {
        final int tag;
        final byte[] value;

        Element(int tag, byte[] value) {
            this.tag = tag;
            this.value = value;
        }
    }

    private Der() {}

    /** The total length of a DER SEQUENCE whose first bytes are {@code header}, or -1. */
    static int encodedLength(byte[] header) {
        if (header.length < 2 || (header[0] & 0xFF) != SEQUENCE) return -1;
        int first = header[1] & 0xFF;
        if (first < 0x80) return 2 + first;
        int count = first & 0x7F;
        if (count < 1 || count > 2 || header.length < 2 + count) return -1;
        int length = 0;
        for (int i = 0; i < count; i++) length = length << 8 | (header[2 + i] & 0xFF);
        return 2 + count + length;
    }

    /** Reads consecutive TLVs. */
    static final class Reader {
        private final byte[] bytes;
        private int index;

        Reader(byte[] bytes) {
            this.bytes = bytes;
        }

        boolean isAtEnd() {
            return index >= bytes.length;
        }

        int peekTag() {
            return isAtEnd() ? -1 : bytes[index] & 0xFF;
        }

        Element next() throws Malformed {
            if (index + 2 > bytes.length) throw new Malformed();
            int tag = bytes[index] & 0xFF;
            int cursor = index + 1;
            int length = bytes[cursor++] & 0xFF;
            if (length >= 0x80) {
                int count = length & 0x7F;
                if (count < 1 || count > 3 || cursor + count > bytes.length) throw new Malformed();
                length = 0;
                for (int i = 0; i < count; i++) length = length << 8 | (bytes[cursor++] & 0xFF);
            }
            if (cursor + length > bytes.length) throw new Malformed();
            index = cursor + length;
            return new Element(tag, Arrays.copyOfRange(bytes, cursor, cursor + length));
        }

        Element next(int expectedTag) throws Malformed {
            Element element = next();
            if (element.tag != expectedTag) throw new Malformed();
            return element;
        }
    }

    /** Parses UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ) in UTC. */
    static Instant time(Element element) throws Malformed {
        String text = new String(element.value, StandardCharsets.US_ASCII);
        if (!text.endsWith("Z")) throw new Malformed();
        String digits = text.substring(0, text.length() - 1);
        if (!digits.chars().allMatch(Character::isDigit)) throw new Malformed();
        int year;
        int rest;
        if (element.tag == UTC_TIME && digits.length() == 12) {
            int yy = Integer.parseInt(digits.substring(0, 2));
            year = yy < 50 ? 2000 + yy : 1900 + yy; // RFC 5280 4.1.2.5.1
            rest = 2;
        } else if (element.tag == GENERALIZED_TIME && digits.length() == 14) {
            year = Integer.parseInt(digits.substring(0, 4));
            rest = 4;
        } else {
            throw new Malformed();
        }
        try {
            return LocalDateTime.of(
                    year,
                    Integer.parseInt(digits.substring(rest, rest + 2)),
                    Integer.parseInt(digits.substring(rest + 2, rest + 4)),
                    Integer.parseInt(digits.substring(rest + 4, rest + 6)),
                    Integer.parseInt(digits.substring(rest + 6, rest + 8)),
                    Integer.parseInt(digits.substring(rest + 8, rest + 10)))
                .toInstant(ZoneOffset.UTC);
        } catch (DateTimeException e) {
            throw new Malformed();
        }
    }
}
