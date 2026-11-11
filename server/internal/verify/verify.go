// Package verify checks a certificate read from a My Number card by ICReadKit.
//
// The device only reads; this package decides. It builds the chain to a trusted
// certification authority, checks the validity period and the key usage, and asks
// a revocation checker. It never stores or logs the certificate.
//
// What a passing result proves: a genuine, currently valid JPKI user-authentication
// certificate was presented. What it does not prove: that the person holds the card.
// The certificate is public, so proving possession needs the card to sign a fresh
// challenge, which needs the card's PIN. ICReadKit does not use PINs.
package verify

import (
	"context"
	"crypto/x509"
	"errors"
	"time"
)

// Revocation is what a revocation checker says about a certificate.
type Revocation string

const (
	RevocationGood       Revocation = "good"
	RevocationRevoked    Revocation = "revoked"
	RevocationNotChecked Revocation = "not_checked"
)

// RevocationChecker asks OCSP or a CRL. For JPKI this goes through a platform operator
// approved by the Digital Agency; NotChecked is the honest answer without one.
type RevocationChecker interface {
	Check(ctx context.Context, certificate, issuer *x509.Certificate) (Revocation, error)
}

// NotChecked is the checker used until a platform operator is connected.
type NotChecked struct{}

func (NotChecked) Check(context.Context, *x509.Certificate, *x509.Certificate) (Revocation, error) {
	return RevocationNotChecked, nil
}

// Reason names why a certificate is not accepted. The values are part of the API contract.
type Reason string

const (
	ReasonMalformed      Reason = "malformed"
	ReasonUntrustedChain Reason = "untrusted_chain"
	ReasonExpired        Reason = "expired"
	ReasonNotYetValid    Reason = "not_yet_valid"
	ReasonWrongKeyUsage  Reason = "wrong_key_usage"
	ReasonRevoked        Reason = "revoked"
)

// Result is everything the server tells the host app's backend. It holds no serial
// number, subject or key, the same rule the SDK follows.
type Result struct {
	Accepted   bool       `json:"accepted"`
	Reasons    []Reason   `json:"reasons"`
	Issuer     string     `json:"issuer"`
	NotBefore  time.Time  `json:"notBefore"`
	NotAfter   time.Time  `json:"notAfter"`
	Revocation Revocation `json:"revocation"`
}

// Verifier holds the trust anchors and the revocation checker.
type Verifier struct {
	Roots         *x509.CertPool
	Intermediates *x509.CertPool
	Revocation    RevocationChecker
	Now           func() time.Time
}

// ErrMalformed means the bytes are not a DER certificate.
var ErrMalformed = errors.New("verify: not a DER certificate")

// Verify checks one DER certificate. A certificate that parses always yields a Result,
// accepted or not with reasons; only bytes that are not a certificate return an error.
func (v Verifier) Verify(ctx context.Context, der []byte) (Result, error) {
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		return Result{Reasons: []Reason{ReasonMalformed}, Revocation: RevocationNotChecked}, ErrMalformed
	}
	now := v.now()
	result := Result{
		Issuer:     issuerName(certificate),
		NotBefore:  certificate.NotBefore,
		NotAfter:   certificate.NotAfter,
		Revocation: RevocationNotChecked,
		Reasons:    []Reason{},
	}

	switch {
	case now.Before(certificate.NotBefore):
		result.Reasons = append(result.Reasons, ReasonNotYetValid)
	case now.After(certificate.NotAfter):
		result.Reasons = append(result.Reasons, ReasonExpired)
	}
	// An authentication certificate must be allowed to sign.
	if certificate.KeyUsage != 0 && certificate.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
		result.Reasons = append(result.Reasons, ReasonWrongKeyUsage)
	}

	// The chain is checked at a time inside the validity period, so an expired
	// certificate still reports whether it came from the right authority.
	chains, err := certificate.Verify(x509.VerifyOptions{
		Roots:         v.Roots,
		Intermediates: v.Intermediates,
		CurrentTime:   clamp(now, certificate.NotBefore, certificate.NotAfter),
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	})
	if err != nil || len(chains) == 0 || len(chains[0]) < 2 {
		result.Reasons = append(result.Reasons, ReasonUntrustedChain)
	} else if v.Revocation != nil {
		revocation, err := v.Revocation.Check(ctx, certificate, chains[0][1])
		if err == nil {
			result.Revocation = revocation
		}
		if revocation == RevocationRevoked {
			result.Reasons = append(result.Reasons, ReasonRevoked)
		}
	}
	result.Accepted = len(result.Reasons) == 0
	return result, nil
}

func (v Verifier) now() time.Time {
	if v.Now != nil {
		return v.Now()
	}
	return time.Now()
}

func clamp(t, lower, upper time.Time) time.Time {
	if t.Before(lower) {
		return lower
	}
	if t.After(upper) {
		return upper
	}
	return t
}

func issuerName(certificate *x509.Certificate) string {
	if certificate.Issuer.CommonName != "" {
		return certificate.Issuer.CommonName
	}
	parts := append([]string{}, certificate.Issuer.OrganizationalUnit...)
	parts = append(parts, certificate.Issuer.Organization...)
	name := ""
	for i, part := range parts {
		if i > 0 {
			name += " / "
		}
		name += part
	}
	return name
}
