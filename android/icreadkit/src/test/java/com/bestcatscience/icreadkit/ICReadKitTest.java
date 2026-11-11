package com.bestcatscience.icreadkit;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.List;
import org.junit.Test;

public class ICReadKitTest {
    /** Replays scripted responses and records every command it receives. */
    static final class ScriptedTransport implements CardTransport {
        final List<CommandApdu> sent = new ArrayList<>();
        private final Deque<Object> responses = new ArrayDeque<>();

        ScriptedTransport(Object... responses) {
            this.responses.addAll(Arrays.asList(responses));
        }

        @Override
        public ResponseApdu transmit(CommandApdu command) throws CardReadException {
            sent.add(command);
            Object next = responses.isEmpty() ? new CardReadException(CardReadException.Reason.CONNECTION_LOST) : responses.removeFirst();
            if (next instanceof CardReadException) throw (CardReadException) next;
            return (ResponseApdu) next;
        }
    }

    private static ResponseApdu ok(byte... data) { return new ResponseApdu(data, 0x9000); }
    private static ResponseApdu status(int sw) { return new ResponseApdu(new byte[0], sw); }
    private static byte[] hex(String text) {
        byte[] out = new byte[text.length() / 2];
        for (int i = 0; i < out.length; i++) out[i] = (byte) Integer.parseInt(text.substring(i * 2, i * 2 + 2), 16);
        return out;
    }

    private static CardReadException.Reason readFails(ScriptedTransport transport) {
        try {
            new JpkiReader(transport).readAuthenticationCertificate();
            fail("expected a failure");
            return null;
        } catch (CardReadException e) {
            return e.getReason();
        }
    }

    // Commands

    @Test public void selectingTheJpkiApplicationMatchesThePublishedBytes() {
        assertArrayEquals(hex("00A4040C0AD392F000260100000001"), CommandApdu.selectApplication(JpkiReader.APPLICATION_ID).bytes());
    }

    @Test public void selectingTheCertificateFileUsesItsTwoByteIdentifier() {
        assertArrayEquals(hex("00A4020C02000A"), CommandApdu.selectFile(JpkiReader.AUTHENTICATION_CERTIFICATE_FILE).bytes());
    }

    @Test public void readBinaryPutsTheOffsetInP1P2AndSends256AsZero() {
        assertArrayEquals(hex("00B0010400"), CommandApdu.readBinary(0x0104, 256).bytes());
        assertArrayEquals(hex("00B0000004"), CommandApdu.readBinary(0, 4).bytes());
    }

    @Test public void theKitCanOnlyBuildSelectAndReadBinary() {
        // VERIFY (0x20), CHANGE REFERENCE DATA (0x24) and RESET RETRY COUNTER (0x2C) touch PINs.
        assertEquals(2, CommandApdu.ALLOWED.size());
        assertTrue(CommandApdu.ALLOWED.contains(CommandApdu.INS_SELECT));
        assertTrue(CommandApdu.ALLOWED.contains(CommandApdu.INS_READ_BINARY));
    }

    // Reading

    @Test public void readsTheCertificateInChunksFromTheHeaderLength() throws Exception {
        byte[] certificate = SyntheticCertificate.make(DemoCard.VALID, Instant.parse("2026-11-11T00:00:00Z"));
        assertTrue(certificate.length > 512);
        List<Object> responses = new ArrayList<>(Arrays.asList(ok(), ok(), ok(Arrays.copyOf(certificate, 4))));
        List<CommandApdu> expected = new ArrayList<>(Arrays.asList(
            CommandApdu.selectApplication(JpkiReader.APPLICATION_ID),
            CommandApdu.selectFile(JpkiReader.AUTHENTICATION_CERTIFICATE_FILE),
            CommandApdu.readBinary(0, 4)));
        for (int offset = 4; offset < certificate.length; ) {
            int end = Math.min(certificate.length, offset + 256);
            expected.add(CommandApdu.readBinary(offset, end - offset));
            responses.add(ok(Arrays.copyOfRange(certificate, offset, end)));
            offset = end;
        }
        ScriptedTransport transport = new ScriptedTransport(responses.toArray());

        assertArrayEquals(certificate, new JpkiReader(transport).readAuthenticationCertificate());
        assertEquals(expected, transport.sent);
    }

    @Test public void aCardWithoutTheApplicationIsUnsupportedNotACrash() {
        ScriptedTransport transport = new ScriptedTransport(status(0x6A82));
        assertEquals(CardReadException.Reason.UNSUPPORTED_CARD, readFails(transport));
        assertEquals(1, transport.sent.size());
    }

    @Test public void otherRefusalsKeepTheirStatusWord() {
        try {
            new JpkiReader(new ScriptedTransport(ok(), status(0x6982))).readAuthenticationCertificate();
            fail("expected a failure");
        } catch (CardReadException e) {
            assertEquals(CardReadException.Reason.CARD_REJECTED, e.getReason());
            assertEquals(0x6982, e.getStatusWord());
        }
    }

    @Test public void aHeaderThatIsNotACertificateStopsTheRead() {
        ScriptedTransport transport = new ScriptedTransport(ok(), ok(), ok(hex("04820100")));
        assertEquals(CardReadException.Reason.MALFORMED_CERTIFICATE, readFails(transport));
        assertEquals(3, transport.sent.size());
    }

    @Test public void anEmptyChunkStopsInsteadOfLoopingForever() {
        assertEquals(CardReadException.Reason.MALFORMED_CERTIFICATE,
            readFails(new ScriptedTransport(ok(), ok(), ok(hex("30820100")), ok())));
    }

    @Test public void aLostConnectionMidReadSurfacesAsConnectionLost() {
        assertEquals(CardReadException.Reason.CONNECTION_LOST, readFails(new ScriptedTransport(
            ok(), ok(), ok(hex("30820100")), new CardReadException(CardReadException.Reason.CONNECTION_LOST))));
    }

    @Test public void aTooShortResponseIsAConnectionProblem() {
        try {
            ResponseApdu.parse(new byte[] {(byte) 0x90});
            fail("expected a failure");
        } catch (CardReadException e) {
            assertEquals(CardReadException.Reason.CONNECTION_LOST, e.getReason());
        }
    }

    // Certificates

    @Test public void readsTheIssuerAndValidityAndDropsEverythingElse() throws Exception {
        Instant notBefore = Instant.parse("2024-04-01T00:00:00Z");
        Instant notAfter = Instant.parse("2029-03-31T14:59:59Z");
        CertificateSummary summary = CertificateSummary.parse(SyntheticCertificate.make("Test Authority", notBefore, notAfter));
        assertEquals(new CertificateSummary("Test Authority / ICReadKit", notBefore, notAfter), summary);
    }

    @Test public void expiredIsAResultNotAnError() throws Exception {
        Instant now = Instant.parse("2026-11-11T00:00:00Z");
        CertificateSummary summary = CertificateSummary.parse(SyntheticCertificate.make(DemoCard.EXPIRED, now));
        assertEquals(CertificateSummary.Validity.EXPIRED, summary.validity(now));
        assertEquals(CertificateSummary.Validity.NOT_YET_VALID, summary.validity(summary.getNotBefore().minusSeconds(1)));
        assertEquals(CertificateSummary.Validity.VALID, summary.validity(summary.getNotBefore()));
    }

    @Test public void utcTimeYearsFollowRfc5280() throws Exception {
        assertEquals(Instant.parse("2049-12-31T23:59:59Z"), Der.time(new Der.Element(Der.UTC_TIME, "491231235959Z".getBytes(StandardCharsets.US_ASCII))));
        assertEquals(Instant.parse("1950-01-01T00:00:00Z"), Der.time(new Der.Element(Der.UTC_TIME, "500101000000Z".getBytes(StandardCharsets.US_ASCII))));
    }

    @Test public void impossibleDatesAreRejected() {
        for (String text : new String[] {"20261301000000Z", "20261101000000"}) {
            try {
                Der.time(new Der.Element(Der.GENERALIZED_TIME, text.getBytes(StandardCharsets.US_ASCII)));
                fail("expected " + text + " to be rejected");
            } catch (Der.Malformed expected) {
                // rejected as it should be
            }
        }
    }

    @Test public void truncatedCertificatesAreMalformed() {
        byte[] certificate = SyntheticCertificate.make(DemoCard.VALID, Instant.now());
        for (byte[] broken : new byte[][] {Arrays.copyOf(certificate, 40), new byte[0]}) {
            try {
                CertificateSummary.parse(broken);
                fail("expected a failure");
            } catch (CardReadException e) {
                assertEquals(CardReadException.Reason.MALFORMED_CERTIFICATE, e.getReason());
            }
        }
    }

    // Sessions and events

    @Test public void theDemoCardsCoverTheResultsAHostAppMustHandle() throws Exception {
        CardReader reader = new CardReader();
        assertEquals(CertificateSummary.Validity.VALID, reader.startDemoSession().readDemo(DemoCard.VALID).validity());
        assertEquals(CertificateSummary.Validity.EXPIRED, reader.startDemoSession().readDemo(DemoCard.EXPIRED).validity());
        for (DemoCard card : new DemoCard[] {DemoCard.OTHER_CARD, DemoCard.CONNECTION_LOST}) {
            try {
                reader.startDemoSession().readDemo(card);
                fail("expected " + card + " to fail");
            } catch (CardReadException e) {
                assertEquals(card == DemoCard.OTHER_CARD ? CardReadException.Reason.UNSUPPORTED_CARD : CardReadException.Reason.CONNECTION_LOST, e.getReason());
            }
        }
    }

    @Test public void aSuccessfulReadWalksTheWholeFunnel() throws Exception {
        List<String> events = new ArrayList<>();
        new CardReader(event -> events.add(event.toString())).startDemoSession().readDemo(DemoCard.VALID);
        assertEquals(Arrays.asList("STARTED(demo)", "CARD_DETECTED(1)", "FINISHED(READ:VALID)"), events);
    }

    @Test public void aFailureReportsItsReasonOnceAndACancelAfterwardsIsIgnored() {
        List<String> events = new ArrayList<>();
        CardReader.Session session = new CardReader(event -> events.add(event.toString())).startDemoSession();
        try {
            session.readDemo(DemoCard.CONNECTION_LOST);
            fail("expected a failure");
        } catch (CardReadException expected) {
            session.cancel();
        }
        assertEquals(Arrays.asList("STARTED(demo)", "CARD_DETECTED(1)", "FINISHED(FAILED:CONNECTION_LOST)"), events);
    }

    @Test public void cancellingBeforeACardIsAnAbandonedRead() {
        List<String> events = new ArrayList<>();
        new CardReader(event -> events.add(event.toString())).startDemoSession().cancel();
        assertEquals(Arrays.asList("STARTED(demo)", "FINISHED(CANCELLED)"), events);
    }

    @Test public void theDemoCardIdentifiersMatchTheIosKit() {
        assertEquals(Arrays.asList("valid", "expired", "other-card", "connection-lost"),
            Arrays.stream(DemoCard.values()).map(card -> card.id).collect(java.util.stream.Collectors.toList()));
    }

    @Test public void theVerifiableReadReturnsTheExactBytesTheSummaryCameFrom() throws Exception {
        VerifiableCertificate read = new CardReader().startDemoSession().readDemoForVerification(DemoCard.VALID);
        assertEquals(CertificateSummary.parse(read.getDer()), read.getSummary());
        assertEquals(0x30, read.getDer()[0] & 0xFF);
        // The bytes handed out are a copy; changing them does not change the kit's copy.
        read.getDer()[0] = 0;
        assertEquals(0x30, read.getDer()[0] & 0xFF);
    }
}
