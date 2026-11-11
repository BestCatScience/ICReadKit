package com.bestcatscience.icreadkit;

import java.util.Arrays;

/** A card's response: the data and the two status bytes. */
final class ResponseApdu {
    final byte[] data;
    final int statusWord;

    ResponseApdu(byte[] data, int statusWord) {
        this.data = data.clone();
        this.statusWord = statusWord;
    }

    /** Splits a raw IsoDep response into data and the trailing status word. */
    static ResponseApdu parse(byte[] raw) throws CardReadException {
        if (raw == null || raw.length < 2) throw new CardReadException(CardReadException.Reason.CONNECTION_LOST);
        int sw = (raw[raw.length - 2] & 0xFF) << 8 | (raw[raw.length - 1] & 0xFF);
        return new ResponseApdu(Arrays.copyOf(raw, raw.length - 2), sw);
    }

    boolean isSuccess() {
        return statusWord == 0x9000;
    }
}
