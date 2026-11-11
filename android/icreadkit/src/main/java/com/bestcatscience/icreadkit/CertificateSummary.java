package com.bestcatscience.icreadkit;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;

/**
 * What the kit tells the host app about the certificate: who issued it and when it is valid. The
 * serial number, the subject, the public key and the certificate bytes never leave the kit.
 */
public final class CertificateSummary {
    public enum Validity { VALID, EXPIRED, NOT_YET_VALID }

    private static final byte[] COMMON_NAME = {0x55, 0x04, 0x03};
    private static final byte[] ORGANIZATION = {0x55, 0x04, 0x0A};
    private static final byte[] ORGANIZATIONAL_UNIT = {0x55, 0x04, 0x0B};

    private final String issuer;
    private final Instant notBefore;
    private final Instant notAfter;

    public CertificateSummary(String issuer, Instant notBefore, Instant notAfter) {
        this.issuer = issuer;
        this.notBefore = notBefore;
        this.notAfter = notAfter;
    }

    public String getIssuer() { return issuer; }
    public Instant getNotBefore() { return notBefore; }
    public Instant getNotAfter() { return notAfter; }

    /** An expired certificate is a normal result, not an error: the host app decides what to say. */
    public Validity validity(Instant now) {
        if (now.isBefore(notBefore)) return Validity.NOT_YET_VALID;
        if (now.isAfter(notAfter)) return Validity.EXPIRED;
        return Validity.VALID;
    }

    public Validity validity() {
        return validity(Instant.now());
    }

    /** Reads the issuer and the validity period from an X.509 certificate in DER. */
    static CertificateSummary parse(byte[] certificate) throws CardReadException {
        try {
            Der.Reader outer = new Der.Reader(certificate);
            Der.Reader certificateFields = new Der.Reader(outer.next(Der.SEQUENCE).value);
            Der.Reader fields = new Der.Reader(certificateFields.next(Der.SEQUENCE).value);
            if (fields.peekTag() == Der.EXPLICIT_VERSION) fields.next();
            fields.next(Der.INTEGER); // serial number, not kept
            fields.next(Der.SEQUENCE); // signature algorithm
            byte[] issuerName = fields.next(Der.SEQUENCE).value;
            Der.Reader times = new Der.Reader(fields.next(Der.SEQUENCE).value);
            Instant notBefore = Der.time(times.next());
            Instant notAfter = Der.time(times.next());
            if (notBefore.isAfter(notAfter)) throw new Der.Malformed();
            return new CertificateSummary(displayName(issuerName), notBefore, notAfter);
        } catch (Der.Malformed e) {
            throw new CardReadException(CardReadException.Reason.MALFORMED_CERTIFICATE);
        }
    }

    private static String displayName(byte[] name) throws Der.Malformed {
        List<String> commonNames = new ArrayList<>();
        List<String> parts = new ArrayList<>();
        List<String> organizations = new ArrayList<>();
        Der.Reader relativeNames = new Der.Reader(name);
        while (!relativeNames.isAtEnd()) {
            Der.Reader attributes = new Der.Reader(relativeNames.next(Der.SET).value);
            while (!attributes.isAtEnd()) {
                Der.Reader pair = new Der.Reader(attributes.next(Der.SEQUENCE).value);
                byte[] type = pair.next(Der.OBJECT_IDENTIFIER).value;
                Der.Element value = pair.next();
                if (value.tag != Der.UTF8_STRING && value.tag != Der.PRINTABLE_STRING) continue;
                String text = new String(value.value, StandardCharsets.UTF_8);
                if (Arrays.equals(type, COMMON_NAME)) commonNames.add(text);
                else if (Arrays.equals(type, ORGANIZATIONAL_UNIT)) parts.add(text);
                else if (Arrays.equals(type, ORGANIZATION)) organizations.add(text);
            }
        }
        if (!commonNames.isEmpty()) return commonNames.get(0);
        parts.addAll(organizations);
        return String.join(" / ", parts);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CertificateSummary)) return false;
        CertificateSummary that = (CertificateSummary) other;
        return issuer.equals(that.issuer) && notBefore.equals(that.notBefore) && notAfter.equals(that.notAfter);
    }

    @Override
    public int hashCode() {
        return Objects.hash(issuer, notBefore, notAfter);
    }
}
