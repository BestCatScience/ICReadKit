// Command icreadkit-verifier serves the certificate verifier.
//
//	icreadkit-verifier -roots jlis-ca.pem -addr :8080
//
// -roots is a PEM file of the certification authorities to trust: for JPKI, the
// J-LIS user-authentication CA certificates. Revocation is reported as not_checked
// until a JPKI platform operator is connected.
package main

import (
	"crypto/x509"
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/BestCatScience/ICReadKit/server/internal/httpapi"
	"github.com/BestCatScience/ICReadKit/server/internal/verify"
)

func main() {
	addr := flag.String("addr", ":8080", "address to listen on")
	rootsPath := flag.String("roots", "", "PEM file of trusted CA certificates")
	flag.Parse()

	pem, err := os.ReadFile(*rootsPath)
	if err != nil {
		log.Fatalf("read roots: %v", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		log.Fatal("no certificates in the roots file")
	}
	server := &http.Server{
		Addr:              *addr,
		Handler:           httpapi.New(verify.Verifier{Roots: roots, Revocation: verify.NotChecked{}}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
	}
	log.Printf("listening on %s", *addr)
	log.Fatal(server.ListenAndServe())
}
