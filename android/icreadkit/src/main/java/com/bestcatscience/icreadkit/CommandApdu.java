package com.bestcatscience.icreadkit;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.Set;

/**
 * An ISO/IEC 7816-4 command in the short form.
 *
 * <p>Only SELECT and READ BINARY can be built. There is deliberately no builder for VERIFY or any
 * other command that presents a PIN, because a wrong PIN counts toward locking the card.
 */
final class CommandApdu {
    static final byte INS_SELECT = (byte) 0xA4;
    static final byte INS_READ_BINARY = (byte) 0xB0;
    /** Everything the kit is allowed to send. */
    static final Set<Byte> ALLOWED = Set.of(INS_SELECT, INS_READ_BINARY);

    final byte ins;
    final byte p1;
    final byte p2;
    final byte[] data;
    /** The expected response length; 256 is sent as 0x00, -1 sends no Le. */
    final int expectedLength;

    private CommandApdu(byte ins, int p1, int p2, byte[] data, int expectedLength) {
        this.ins = ins;
        this.p1 = (byte) p1;
        this.p2 = (byte) p2;
        this.data = data.clone();
        this.expectedLength = expectedLength;
    }

    static CommandApdu selectApplication(byte[] identifier) {
        if (identifier.length < 1 || identifier.length > 16) throw new IllegalArgumentException("An AID is 1 to 16 bytes");
        return new CommandApdu(INS_SELECT, 0x04, 0x0C, identifier, -1);
    }

    static CommandApdu selectFile(int identifier) {
        return new CommandApdu(INS_SELECT, 0x02, 0x0C, new byte[] {(byte) (identifier >> 8), (byte) identifier}, -1);
    }

    static CommandApdu readBinary(int offset, int length) {
        if (offset < 0 || offset > 0x7FFF) throw new IllegalArgumentException("READ BINARY offsets are 15 bits");
        if (length < 1 || length > 256) throw new IllegalArgumentException("A short READ BINARY returns 1 to 256 bytes");
        return new CommandApdu(INS_READ_BINARY, offset >> 8, offset & 0xFF, new byte[0], length);
    }

    /** The bytes as they go over the air. */
    byte[] bytes() {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0x00);
        out.write(ins);
        out.write(p1);
        out.write(p2);
        if (data.length > 0) {
            out.write(data.length);
            out.write(data, 0, data.length);
        }
        if (expectedLength >= 0) out.write(expectedLength == 256 ? 0x00 : expectedLength);
        return out.toByteArray();
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof CommandApdu && Arrays.equals(bytes(), ((CommandApdu) other).bytes());
    }

    @Override
    public int hashCode() {
        return Arrays.hashCode(bytes());
    }

    @Override
    public String toString() {
        StringBuilder text = new StringBuilder();
        for (byte b : bytes()) text.append(String.format("%02X", b));
        return text.toString();
    }
}
