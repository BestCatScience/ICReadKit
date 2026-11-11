package httpapi

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/BestCatScience/ICReadKit/server/internal/verify"
)

func selfSigned(t *testing.T) *x509.Certificate {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Root"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, _ := x509.ParseCertificate(der)
	return certificate
}

func post(t *testing.T, handler http.Handler, body string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/v1/certificates/verify", strings.NewReader(body)))
	return recorder
}

func TestStatusCodesFollowTheContract(t *testing.T) {
	root := selfSigned(t)
	handler := New(verify.Verifier{Roots: x509.NewCertPool(), Revocation: verify.NotChecked{}})
	certificate := base64.StdEncoding.EncodeToString(root.Raw)

	if got := post(t, handler, `{"certificate":"`+certificate+`"}`).Code; got != http.StatusOK {
		t.Fatalf("a certificate gets 200, got %d", got)
	}
	if got := post(t, handler, `not json`).Code; got != http.StatusBadRequest {
		t.Fatalf("not json gets 400, got %d", got)
	}
	if got := post(t, handler, `{"certificate":"AQID"}`); got.Code != http.StatusBadRequest || !strings.Contains(got.Body.String(), "malformed") {
		t.Fatalf("non-certificate bytes get 400 malformed, got %d %s", got.Code, got.Body)
	}
	huge := `{"certificate":"` + strings.Repeat("A", MaxBody) + `"}`
	if got := post(t, handler, huge).Code; got != http.StatusRequestEntityTooLarge {
		t.Fatalf("a huge body gets 413, got %d", got)
	}
}

// TestResponsesMatchOpenAPI checks the 200 response against openapi.json: every required
// field present, no undocumented field, and enum values inside their lists.
func TestResponsesMatchOpenAPI(t *testing.T) {
	raw, err := os.ReadFile("../../openapi.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Components struct {
			Schemas map[string]struct {
				Required   []string `json:"required"`
				Properties map[string]struct {
					Enum  []string `json:"enum"`
					Items struct {
						Enum []string `json:"enum"`
					} `json:"items"`
				} `json:"properties"`
			} `json:"schemas"`
		} `json:"components"`
	}
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	schema := spec.Components.Schemas["VerifyResult"]

	handler := New(verify.Verifier{Roots: x509.NewCertPool(), Revocation: verify.NotChecked{}})
	body := `{"certificate":"` + base64.StdEncoding.EncodeToString(selfSigned(t).Raw) + `"}`
	var response map[string]any
	if err := json.NewDecoder(bytes.NewReader(post(t, handler, body).Body.Bytes())).Decode(&response); err != nil {
		t.Fatal(err)
	}

	for _, field := range schema.Required {
		if _, ok := response[field]; !ok {
			t.Errorf("required field %q missing", field)
		}
	}
	var undocumented []string
	for field := range response {
		if _, ok := schema.Properties[field]; !ok {
			undocumented = append(undocumented, field)
		}
	}
	sort.Strings(undocumented)
	if len(undocumented) > 0 {
		t.Errorf("fields not in openapi.json: %v", undocumented)
	}
	if revocation := response["revocation"].(string); !contains(schema.Properties["revocation"].Enum, revocation) {
		t.Errorf("revocation %q not in the enum", revocation)
	}
	for _, reason := range response["reasons"].([]any) {
		if !contains(schema.Properties["reasons"].Items.Enum, reason.(string)) {
			t.Errorf("reason %q not in the enum", reason)
		}
	}
}

// Every reason the verifier can produce must be listed in the contract.
func TestEveryReasonIsInTheContract(t *testing.T) {
	raw, _ := os.ReadFile("../../openapi.json")
	for _, reason := range []verify.Reason{verify.ReasonMalformed, verify.ReasonUntrustedChain, verify.ReasonExpired,
		verify.ReasonNotYetValid, verify.ReasonWrongKeyUsage, verify.ReasonRevoked} {
		if !strings.Contains(string(raw), `"`+string(reason)+`"`) {
			t.Errorf("reason %q is not in openapi.json", reason)
		}
	}
	_ = context.Background()
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}
