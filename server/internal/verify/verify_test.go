package verify

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"testing"
	"time"
)

// pki builds a throwaway root, intermediate and leaf, like J-LIS's hierarchy but synthetic.
type pki struct {
	root, intermediate *x509.Certificate
	rootKey, interKey  *ecdsa.PrivateKey
}

var serial int64

func issue(t *testing.T, template *x509.Certificate, parent *x509.Certificate, parentKey *ecdsa.PrivateKey) (*x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serial++
	template.SerialNumber = big.NewInt(serial)
	if parent == nil {
		parent, parentKey = template, key
	}
	der, err := x509.CreateCertificate(rand.Reader, template, parent, &key.PublicKey, parentKey)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return certificate, key
}

func newPKI(t *testing.T) pki {
	start := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	ca := func(name string) *x509.Certificate {
		return &x509.Certificate{
			Subject: pkix.Name{CommonName: name}, NotBefore: start, NotAfter: start.AddDate(20, 0, 0),
			IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
		}
	}
	root, rootKey := issue(t, ca("Test Root"), nil, nil)
	intermediate, interKey := issue(t, ca("Test User Authentication CA"), root, rootKey)
	return pki{root: root, intermediate: intermediate, rootKey: rootKey, interKey: interKey}
}

func (p pki) leaf(t *testing.T, notBefore, notAfter time.Time, usage x509.KeyUsage) []byte {
	certificate, _ := issue(t, &x509.Certificate{
		Subject: pkix.Name{CommonName: "synthetic"}, NotBefore: notBefore, NotAfter: notAfter, KeyUsage: usage,
	}, p.intermediate, p.interKey)
	return certificate.Raw
}

func (p pki) verifier(now time.Time, revocation RevocationChecker) Verifier {
	roots, intermediates := x509.NewCertPool(), x509.NewCertPool()
	roots.AddCert(p.root)
	intermediates.AddCert(p.intermediate)
	return Verifier{Roots: roots, Intermediates: intermediates, Revocation: revocation, Now: func() time.Time { return now }}
}

type fixedRevocation Revocation

func (f fixedRevocation) Check(context.Context, *x509.Certificate, *x509.Certificate) (Revocation, error) {
	return Revocation(f), nil
}

func reasons(t *testing.T, r Result) []Reason {
	t.Helper()
	return r.Reasons
}

var (
	issued  = time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	expires = time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC)
	today   = time.Date(2026, 11, 11, 0, 0, 0, 0, time.UTC)
)

func TestAValidCertificateFromTheTrustedAuthorityIsAccepted(t *testing.T) {
	p := newPKI(t)
	result, err := p.verifier(today, fixedRevocation(RevocationGood)).Verify(context.Background(), p.leaf(t, issued, expires, x509.KeyUsageDigitalSignature))
	if err != nil || !result.Accepted || len(result.Reasons) != 0 || result.Revocation != RevocationGood {
		t.Fatalf("got %+v, %v", result, err)
	}
	if result.Issuer != "Test User Authentication CA" || !result.NotAfter.Equal(expires) {
		t.Fatalf("issuer or period wrong: %+v", result)
	}
}

func TestWithoutARevocationSourceTheAnswerSaysSo(t *testing.T) {
	p := newPKI(t)
	result, _ := p.verifier(today, NotChecked{}).Verify(context.Background(), p.leaf(t, issued, expires, x509.KeyUsageDigitalSignature))
	if !result.Accepted || result.Revocation != RevocationNotChecked {
		t.Fatalf("got %+v", result)
	}
}

func TestEachReasonIsReported(t *testing.T) {
	p := newPKI(t)
	other := newPKI(t)
	cases := []struct {
		name   string
		der    []byte
		now    time.Time
		rev    RevocationChecker
		reason Reason
	}{
		{"expired", p.leaf(t, issued, today.AddDate(0, 0, -1), x509.KeyUsageDigitalSignature), today, NotChecked{}, ReasonExpired},
		{"not yet valid", p.leaf(t, today.AddDate(0, 0, 1), expires, x509.KeyUsageDigitalSignature), today, NotChecked{}, ReasonNotYetValid},
		{"another authority", other.leaf(t, issued, expires, x509.KeyUsageDigitalSignature), today, NotChecked{}, ReasonUntrustedChain},
		{"cannot sign", p.leaf(t, issued, expires, x509.KeyUsageKeyEncipherment), today, NotChecked{}, ReasonWrongKeyUsage},
		{"revoked", p.leaf(t, issued, expires, x509.KeyUsageDigitalSignature), today, fixedRevocation(RevocationRevoked), ReasonRevoked},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			result, err := p.verifier(c.now, c.rev).Verify(context.Background(), c.der)
			if err != nil || result.Accepted || len(result.Reasons) != 1 || result.Reasons[0] != c.reason {
				t.Fatalf("want only %s, got %+v %v", c.reason, reasons(t, result), err)
			}
		})
	}
}

func TestAnExpiredCertificateStillSaysWhetherItsChainIsTrusted(t *testing.T) {
	p := newPKI(t)
	result, _ := p.verifier(today, NotChecked{}).Verify(context.Background(), p.leaf(t, issued, today.AddDate(0, 0, -1), x509.KeyUsageDigitalSignature))
	for _, reason := range result.Reasons {
		if reason == ReasonUntrustedChain {
			t.Fatalf("an expired certificate from the trusted authority should not be untrusted: %+v", result)
		}
	}
}

func TestBytesThatAreNotACertificateAreMalformed(t *testing.T) {
	p := newPKI(t)
	if _, err := p.verifier(today, NotChecked{}).Verify(context.Background(), []byte{0x30, 0x03, 0x01}); err != ErrMalformed {
		t.Fatalf("want ErrMalformed, got %v", err)
	}
}
