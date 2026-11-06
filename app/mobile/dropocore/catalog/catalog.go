package catalog

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"dropocore/dnspolicy"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"time"
)

// Public verification key; the corresponding signing seed never enters builds.
const publicKey = "3TD8w4fTcxEAObafXvUVKlt75iXDN2yShIBDBOsexH8"

type Payload struct {
	SchemaVersion  int              `json:"schemaVersion"`
	ServiceID      string           `json:"serviceId"`
	Revision       int64            `json:"revision"`
	IssuedAt       time.Time        `json:"issuedAt"`
	ExpiresAt      time.Time        `json:"expiresAt"`
	DNS            dnspolicy.Policy `json:"dnsPolicy"`
	AccountOrigins []string         `json:"accountOrigins"`
	Pools          []string         `json:"pools"`
	Transport      string           `json:"transport"`
}

func strict(raw []byte, target any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		return err
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("trailing data")
	}
	return nil
}
func Verify(raw []byte, minimum int64, now time.Time) (Payload, error) {
	key, _ := base64.RawURLEncoding.DecodeString(publicKey)
	return verify(raw, minimum, now, ed25519.PublicKey(key))
}
func verify(raw []byte, minimum int64, now time.Time, key ed25519.PublicKey) (Payload, error) {
	var p Payload
	var e struct {
		KeyID     string `json:"keyId"`
		Payload   string `json:"payload"`
		Signature string `json:"signature"`
	}
	bad := errors.New("untrusted deployment catalog")
	if len(raw) > 65536 || strict(raw, &e) != nil {
		return p, bad
	}
	hash := sha256.Sum256(key)
	if e.KeyID != "dropo-"+hex.EncodeToString(hash[:8]) {
		return p, bad
	}
	body, err := base64.RawURLEncoding.DecodeString(e.Payload)
	if err != nil || len(body) > 16384 {
		return p, bad
	}
	sig, err := base64.RawURLEncoding.DecodeString(e.Signature)
	if err != nil || !ed25519.Verify(key, body, sig) || strict(body, &p) != nil {
		return p, bad
	}
	if p.SchemaVersion != 1 || p.ServiceID != "dropo-account-prod" || p.Revision < 1 || p.Revision < minimum || p.IssuedAt.After(now.Add(5*time.Minute)) || !p.ExpiresAt.After(now) || p.ExpiresAt.Sub(p.IssuedAt) > 48*time.Hour || p.ExpiresAt.Before(p.IssuedAt) || p.DNS.Validate() != nil || p.Transport != "xhttp-tls-h2" {
		return Payload{}, bad
	}
	if len(p.AccountOrigins) != 2 || p.AccountOrigins[0] != "https://api.droponevedimka.ru" || p.AccountOrigins[1] != "https://dropo.fun" || len(p.Pools) != 2 || p.Pools[0] != "free" || p.Pools[1] != "boost" {
		return Payload{}, bad
	}
	return p, nil
}
