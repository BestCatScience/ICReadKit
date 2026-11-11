package com.bestcatscience.icreadkit;

/**
 * One step of a read, for measuring where people give up. It carries no card data, so a host app
 * can forward it to its analytics as is. The funnel is STARTED, CARD_DETECTED, then FINISHED with
 * {@link Outcome#READ}; the same steps the iOS kit reports.
 */
public final class CardReadEvent {
    public enum Kind { STARTED, CARD_DETECTED, FINISHED }

    public enum Outcome { READ, CANCELLED, FAILED }

    public interface Listener {
        /** Called on the thread that is reading; post to the main thread before touching views. */
        void onEvent(CardReadEvent event);
    }

    public final Kind kind;
    public final boolean demo;
    /** For CARD_DETECTED, how many cards this session has seen; 2 or more means it moved away and back. */
    public final int attempt;
    /** For FINISHED. */
    public final Outcome outcome;
    /** For FINISHED with READ. */
    public final CertificateSummary.Validity validity;
    /** For FINISHED with FAILED. */
    public final CardReadException.Reason failure;
    /** For FINISHED, milliseconds since STARTED. */
    public final long durationMillis;

    private CardReadEvent(Kind kind, boolean demo, int attempt, Outcome outcome,
                          CertificateSummary.Validity validity, CardReadException.Reason failure, long durationMillis) {
        this.kind = kind;
        this.demo = demo;
        this.attempt = attempt;
        this.outcome = outcome;
        this.validity = validity;
        this.failure = failure;
        this.durationMillis = durationMillis;
    }

    static CardReadEvent started(boolean demo) {
        return new CardReadEvent(Kind.STARTED, demo, 0, null, null, null, 0);
    }

    static CardReadEvent cardDetected(boolean demo, int attempt) {
        return new CardReadEvent(Kind.CARD_DETECTED, demo, attempt, null, null, null, 0);
    }

    static CardReadEvent read(boolean demo, CertificateSummary.Validity validity, long durationMillis) {
        return new CardReadEvent(Kind.FINISHED, demo, 0, Outcome.READ, validity, null, durationMillis);
    }

    static CardReadEvent cancelled(boolean demo, long durationMillis) {
        return new CardReadEvent(Kind.FINISHED, demo, 0, Outcome.CANCELLED, null, null, durationMillis);
    }

    static CardReadEvent failed(boolean demo, CardReadException.Reason failure, long durationMillis) {
        return new CardReadEvent(Kind.FINISHED, demo, 0, Outcome.FAILED, null, failure, durationMillis);
    }

    @Override
    public String toString() {
        switch (kind) {
            case STARTED: return demo ? "STARTED(demo)" : "STARTED";
            case CARD_DETECTED: return "CARD_DETECTED(" + attempt + ")";
            default: return "FINISHED(" + outcome + (validity != null ? ":" + validity : "") + (failure != null ? ":" + failure : "") + ")";
        }
    }
}
