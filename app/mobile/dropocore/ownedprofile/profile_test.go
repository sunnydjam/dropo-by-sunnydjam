package ownedprofile

import (
	"strings"
	"testing"
	"time"
)

func TestOwnedPoolIngressAndExpiryAreBounded(t *testing.T) {
	raw := "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"
	if _, err := Validate(Free, raw); err != nil {
		t.Fatal(err)
	}
	if _, err := Validate(Boost, raw); err == nil {
		t.Fatal("Free key accepted as Boost")
	}
	if _, err := Validate(Free, strings.ReplaceAll(raw, "security=tls", "security=none")); err == nil {
		t.Fatal("TLS downgrade")
	}
	if _, err := Validate(Free, strings.ReplaceAll(raw, "@193.233.88.97", "@127.0.0.1")); err == nil {
		t.Fatal("private ingress")
	}
	boost := strings.ReplaceAll(strings.ReplaceAll(raw, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=1000")
	if !Expired(Boost, boost, time.Unix(1001, 0)) {
		t.Fatal("expired Boost retained")
	}
}
