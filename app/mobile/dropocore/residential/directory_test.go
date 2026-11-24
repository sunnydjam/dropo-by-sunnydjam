package residential

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net"
	"slices"
	"strings"
	"testing"
)

func TestWANChangeRetriesOnlyANewVerifiedAddress(t *testing.T) {
	old := assignment{IP: "192.0.2.1", Port: 34443}
	newer := assignment{IP: "198.51.100.2", Port: 34443}
	for _, next := range []assignment{newer, old, {}} {
		var lookups []bool
		var sockets []string
		resolve := func(_ context.Context, _ Dial, force bool) (assignment, error) {
			lookups = append(lookups, force)
			if !force {
				return old, nil
			}
			if next.IP == "" {
				return assignment{}, unavailable
			}
			return next, nil
		}
		dial := func(_ context.Context, _, address string) (net.Conn, error) {
			sockets = append(sockets, address)
			if address == "198.51.100.2:34443" {
				a, b := net.Pipe()
				b.Close()
				return a, nil
			}
			return nil, unavailable
		}
		conn, err := connectWithRefresh(context.Background(), dial, resolve)
		expected := []string{"192.0.2.1:34443"}
		if next.IP == newer.IP {
			if err != nil || conn == nil {
				t.Fatal("new WAN did not restore the connection")
			}
			conn.Close()
			expected = append(expected, "198.51.100.2:34443")
		} else if conn != nil || err == nil {
			t.Fatal("unavailable or unchanged WAN was accepted")
		}
		if !slices.Equal(lookups, []bool{false, true}) || !slices.Equal(sockets, expected) {
			t.Fatalf("unexpected refresh or connect sequence %v %v", lookups, sockets)
		}
	}
}

func TestAssignmentRequiresSubscriptionKeyAndDeploymentSignature(t *testing.T) {
	primary := "a49d8d1a-625f-4c2c-98f6-092784a85e91"
	regional := "1c06e126-6ec4-4e02-9c55-a994bbe4c5fc"
	host := Host(primary, "free")
	c := ForHost(host, regional)
	if c == nil || strings.Contains(host, primary) || strings.Contains(host, regional) {
		t.Fatal("invalid private locator")
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	verify := func(body, sig []byte) bool { return ed25519.Verify(pub, body, sig) }
	seal := func(a assignment) []byte {
		b, err := json.Marshal(a)
		if err != nil {
			t.Fatal(err)
		}
		block, _ := aes.NewCipher(c.key[:])
		gcm, err := cipher.NewGCMWithRandomNonce(block)
		if err != nil {
			t.Fatal(err)
		}
		return gcm.Seal(nil, nil, append(ed25519.Sign(priv, b), b...), []byte(c.locator))
	}
	a := assignment{Purpose: "dropo-residential-xhttp-v1", Pool: "free", Locator: c.locator, IP: "8.8.8.8", Port: 34443, Issued: 1000, Expires: 1480}
	valid := seal(a)
	if got, err := c.decode(valid, 1100, verify); err != nil || got.IP != a.IP {
		t.Fatal("valid assignment rejected")
	}
	if _, err := c.open(valid, 1100); err == nil {
		t.Fatal("non-deployment signature accepted")
	}
	if _, err := ForHost(host, primary).decode(valid, 1100, verify); err == nil {
		t.Fatal("other device opened assignment")
	}
	for _, change := range []func(*assignment){
		func(a *assignment) { a.IP = "100.64.0.42" }, func(a *assignment) { a.IP = "127.0.0.1" },
		func(a *assignment) { a.Expires = 1100 }, func(a *assignment) { a.Expires = 1490 },
		func(a *assignment) { a.Issued = 1150 }, func(a *assignment) { a.Pool = "boost" },
		func(a *assignment) { a.Port = 22 }, func(a *assignment) { a.Locator = "other" },
		func(a *assignment) { a.Purpose = "wrong" },
	} {
		invalid := a
		change(&invalid)
		if _, err := c.decode(seal(invalid), 1100, verify); err == nil {
			t.Fatalf("accepted %+v", invalid)
		}
	}
	valid[len(valid)-1] ^= 1
	if _, err := c.decode(valid, 1100, verify); err == nil {
		t.Fatal("accepted corrupted assignment")
	}
}
