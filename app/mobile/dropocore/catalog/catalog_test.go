package catalog

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"dropocore/dnspolicy"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"
)

func TestCatalogSignatureIssuerExpiryAndRollback(t *testing.T) {
	key, priv, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Now().UTC()
	p := Payload{1, "dropo-account-prod", 3, now, now.Add(time.Hour), dnspolicy.Default(), []string{"https://api.droponevedimka.ru", "https://dropo.fun"}, []string{"free", "boost"}, "xhttp-tls-h2"}
	seal := func(p Payload) []byte {
		body, _ := json.Marshal(p)
		hash := sha256.Sum256(key)
		raw, _ := json.Marshal(map[string]string{"keyId": "dropo-" + hex.EncodeToString(hash[:8]), "payload": base64.RawURLEncoding.EncodeToString(body), "signature": base64.RawURLEncoding.EncodeToString(ed25519.Sign(priv, body))})
		return raw
	}
	raw := seal(p)
	if _, err := verify(raw, 2, now, key); err != nil {
		t.Fatal(err)
	}
	if _, err := verify(raw, 4, now, key); err == nil {
		t.Fatal("rollback accepted")
	}
	if _, err := verify(raw, 2, now.Add(2*time.Hour), key); err == nil {
		t.Fatal("expired metadata accepted")
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := verify(raw, 2, now, other); err == nil {
		t.Fatal("another signing key trusted")
	}
	p.AccountOrigins[0] = "https://evil.example"
	if _, err := verify(seal(p), 2, now, key); err == nil {
		t.Fatal("issuer alias widened")
	}
	p.AccountOrigins[0] = "https://api.droponevedimka.ru"
	p.DNS.Resolvers[0].IPv4 = []string{"127.0.0.1"}
	if _, err := verify(seal(p), 2, now, key); err == nil {
		t.Fatal("signed unsafe DNS accepted")
	}
}
