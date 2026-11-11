package com.bestcatscience.icreadkit;

/**
 * Why a read did not produce a certificate. Every reason says what the host app can do next.
 * The kit never crashes the host app over a card: anything unexpected arrives here instead.
 */
public final class CardReadException extends Exception {
    public enum Reason {
        /** The device has no NFC hardware. Retrying will not help. */
        NO_NFC_HARDWARE,
        /** NFC is turned off. Send the person to the NFC settings. */
        NFC_DISABLED,
        /** The person stopped waiting for a card. Treat it as a normal exit. */
        CANCELLED,
        /** The card moved away mid-read. Ask the person to hold it still and try again. */
        CONNECTION_LOST,
        /** The card has no public key application. It is probably another kind of card. */
        UNSUPPORTED_CARD,
        /** The card refused a command. {@link #getStatusWord()} is for support logs. */
        CARD_REJECTED,
        /** The card returned something that is not a certificate the kit can read. */
        MALFORMED_CERTIFICATE,
    }

    private final Reason reason;
    private final int statusWord;

    public CardReadException(Reason reason) {
        this(reason, 0);
    }

    CardReadException(Reason reason, int statusWord) {
        super(reason.name());
        this.reason = reason;
        this.statusWord = statusWord;
    }

    public Reason getReason() {
        return reason;
    }

    /** The card's status word for {@link Reason#CARD_REJECTED}, otherwise 0. */
    public int getStatusWord() {
        return statusWord;
    }
}
