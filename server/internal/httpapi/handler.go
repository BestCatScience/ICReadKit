// Package httpapi exposes the verifier over HTTP, following openapi.json.
package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/BestCatScience/ICReadKit/server/internal/verify"
)

// MaxBody is the largest request accepted. A JPKI certificate is under 2 KB.
const MaxBody = 16 << 10

type request struct {
	Certificate string `json:"certificate"`
}

type problem struct {
	Error string `json:"error"`
}

// New returns the HTTP handler. It logs nothing about the request body.
func New(verifier verify.Verifier) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/certificates/verify", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, MaxBody)
		var body request
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				w.WriteHeader(http.StatusRequestEntityTooLarge)
				return
			}
			write(w, http.StatusBadRequest, problem{Error: "bad_request"})
			return
		}
		der, err := base64.StdEncoding.DecodeString(body.Certificate)
		if err != nil || len(der) == 0 {
			write(w, http.StatusBadRequest, problem{Error: "bad_request"})
			return
		}
		result, err := verifier.Verify(r.Context(), der)
		if errors.Is(err, verify.ErrMalformed) {
			write(w, http.StatusBadRequest, problem{Error: "malformed"})
			return
		}
		write(w, http.StatusOK, result)
	})
	return mux
}

func write(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
