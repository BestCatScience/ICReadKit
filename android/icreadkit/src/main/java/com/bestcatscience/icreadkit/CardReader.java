package com.bestcatscience.icreadkit;

import android.content.Context;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.TagLostException;
import android.nfc.tech.IsoDep;
import java.io.IOException;
import java.time.Instant;

/**
 * Reads the user authentication certificate from a My Number card.
 *
 * <p>The kit sends only SELECT and READ BINARY, never a PIN, and returns only the issuer and the
 * validity period. A host app checks {@link #availability(Context)}, enables reader mode with
 * {@link #READER_MODE_FLAGS} when the person taps read, calls {@link #startSession()}, and passes
 * each discovered tag to {@link Session#read(Tag)} on the reader-mode callback thread.
 */
public final class CardReader {
    /** The kit's version, for support logs. Matches the iOS kit. */
    public static final String VERSION = "0.4.0";

    /** Flags for {@link NfcAdapter#enableReaderMode}: My Number cards are NFC-B, and NDEF probing only slows them. */
    public static final int READER_MODE_FLAGS = NfcAdapter.FLAG_READER_NFC_B | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK;

    /** How long one command may take before the card counts as moved away. */
    static final int TIMEOUT_MILLIS = 5_000;

    public enum Availability { AVAILABLE, NO_NFC_HARDWARE, NFC_DISABLED }

    private final CardReadEvent.Listener listener;

    public CardReader() {
        this(null);
    }

    public CardReader(CardReadEvent.Listener listener) {
        this.listener = listener != null ? listener : event -> {};
    }

    /** Whether this device can read a card right now. */
    public static Availability availability(Context context) {
        NfcAdapter adapter = NfcAdapter.getDefaultAdapter(context);
        if (adapter == null) return Availability.NO_NFC_HARDWARE;
        return adapter.isEnabled() ? Availability.AVAILABLE : Availability.NFC_DISABLED;
    }

    /** Starts waiting for a real card. Reports STARTED. */
    public Session startSession() {
        return new Session(false);
    }

    /** Starts a session that reads demo cards, for emulators and screen tests. Reports STARTED. */
    public Session startDemoSession() {
        return new Session(true);
    }

    /** One wait for a card, from STARTED to FINISHED. It reports FINISHED exactly once. */
    public final class Session {
        private final boolean demo;
        private final long startNanos = System.nanoTime();
        private int detections;
        private boolean finished;

        private Session(boolean demo) {
            this.demo = demo;
            listener.onEvent(CardReadEvent.started(demo));
        }

        /** Reads a tag from reader mode. Call it off the main thread; it blocks while the card answers. */
        public CertificateSummary read(Tag tag) throws CardReadException {
            return readForVerification(tag).getSummary();
        }

        /**
         * Reads like {@link #read(Tag)} and also returns the certificate itself, for the host app to
         * send to its server. The server checks the chain and revocation; the device cannot.
         */
        public VerifiableCertificate readForVerification(Tag tag) throws CardReadException {
            IsoDep isoDep = IsoDep.get(tag);
            if (isoDep == null) {
                detected();
                throw fail(new CardReadException(CardReadException.Reason.UNSUPPORTED_CARD));
            }
            try {
                isoDep.connect();
                isoDep.setTimeout(TIMEOUT_MILLIS);
                return readVerifiable(new IsoDepTransport(isoDep));
            } catch (IOException e) {
                detected();
                throw fail(new CardReadException(CardReadException.Reason.CONNECTION_LOST));
            } finally {
                try {
                    isoDep.close();
                } catch (IOException ignored) {
                    // The card is gone; there is nothing left to close.
                }
            }
        }

        /** Reads a demo card through the same reading code as a real one. */
        public CertificateSummary readDemo(DemoCard card) throws CardReadException {
            return readDemoForVerification(card).getSummary();
        }

        /** Reads a demo card and returns its synthetic certificate too. */
        public VerifiableCertificate readDemoForVerification(DemoCard card) throws CardReadException {
            return readVerifiable(new DemoTransport(card, Instant.now()));
        }

        /** Reports CANCELLED when the person stops waiting. Does nothing after the session finished. */
        public synchronized void cancel() {
            if (finished) return;
            finished = true;
            listener.onEvent(CardReadEvent.cancelled(demo, elapsedMillis()));
        }

        VerifiableCertificate readVerifiable(CardTransport transport) throws CardReadException {
            detected();
            try {
                byte[] certificate = new JpkiReader(transport).readAuthenticationCertificate();
                CertificateSummary summary = CertificateSummary.parse(certificate);
                finish(CardReadEvent.read(demo, summary.validity(), elapsedMillis()));
                return new VerifiableCertificate(certificate, summary);
            } catch (CardReadException e) {
                throw fail(e);
            }
        }

        private synchronized void detected() {
            detections += 1;
            listener.onEvent(CardReadEvent.cardDetected(demo, detections));
        }

        /** Reports FINISHED with the failure and hands the error back for the caller to throw. */
        private CardReadException fail(CardReadException error) {
            finish(CardReadEvent.failed(demo, error.getReason(), elapsedMillis()));
            return error;
        }

        private synchronized void finish(CardReadEvent event) {
            if (finished) return;
            finished = true;
            listener.onEvent(event);
        }

        private long elapsedMillis() {
            return (System.nanoTime() - startNanos) / 1_000_000;
        }
    }
}

/** Sends command APDUs to a connected IsoDep tag. */
final class IsoDepTransport implements CardTransport {
    private final IsoDep isoDep;

    IsoDepTransport(IsoDep isoDep) {
        this.isoDep = isoDep;
    }

    @Override
    public ResponseApdu transmit(CommandApdu command) throws CardReadException {
        try {
            return ResponseApdu.parse(isoDep.transceive(command.bytes()));
        } catch (TagLostException e) {
            throw new CardReadException(CardReadException.Reason.CONNECTION_LOST);
        } catch (IOException e) {
            throw new CardReadException(CardReadException.Reason.CONNECTION_LOST);
        }
    }
}
