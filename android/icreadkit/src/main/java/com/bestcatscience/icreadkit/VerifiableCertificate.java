package com.bestcatscience.icreadkit;

/**
 * The certificate as read from the card, for verification on the host app's server.
 *
 * <p>The authentication certificate carries no name, address or birth date, but its serial number
 * identifies the card. Send it only to your own server over TLS, and do not log it.
 */
public final class VerifiableCertificate {
    private final byte[] der;
    private final CertificateSummary summary;

    VerifiableCertificate(byte[] der, CertificateSummary summary) {
        this.der = der.clone();
        this.summary = summary;
    }

    /** The DER bytes, to be base64-encoded into the server's {@code certificate} field. */
    public byte[] getDer() {
        return der.clone();
    }

    /** The same issuer and validity {@link CardReader.Session#read} returns. */
    public CertificateSummary getSummary() {
        return summary;
    }
}
