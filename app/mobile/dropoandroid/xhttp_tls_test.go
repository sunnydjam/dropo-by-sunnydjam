package dropoandroid

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/protocol/socks"
)

// A successful config parse is not proof that Android's supplied certificate
// roots or SNI are enforced. Exercise the actual embedded TLS transport and
// ensure an untrusted peer cannot carry even a plain HTTP request to its target.
func TestXHTTPActualTLSRejectsUntrustedRootAndWrongServerName(t *testing.T) {
	for _, scenario := range []string{"unrelated-root", "wrong-server-name"} {
		t.Run(scenario, func(t *testing.T) {
			port, trustedRoot := startXHTTPFixture(t, true)
			outbound := fixtureXHTTPOutbound(port, true)
			root := trustedRoot
			if scenario == "unrelated-root" {
				root, _ = fixtureCertificate(t)
			} else {
				outbound["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)["serverName"] = "wrong-name.example.test"
			}
			built, err := buildXHTTPConfig(encodeXHTTPFixture(t, outbound), []string{root})
			if err != nil {
				t.Fatal("synthetic TLS configuration failed before peer verification")
			}
			var protections atomic.Int32
			bridge, err := newXHTTPBridge(built, func(int32) error { protections.Add(1); return nil }, nil)
			if err != nil {
				t.Fatal("synthetic TLS bridge could not start")
			}
			t.Cleanup(bridge.close)
			var reached atomic.Int32
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				reached.Add(1)
				_, _ = io.WriteString(w, "must-not-cross-untrusted-tls")
			}))
			defer target.Close()
			socksClient := socks.NewClient(xhttpFixtureDialer{}, M.SocksaddrFromNet(bridge.listener.Addr()), socks.Version5, bridge.username, bridge.password)
			transport := &http.Transport{Proxy: nil, DisableKeepAlives: true,
				DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
					return socksClient.DialContext(ctx, network, M.ParseSocksaddr(address))
				}}
			defer transport.CloseIdleConnections()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.URL, nil)
			if err != nil {
				t.Fatal("synthetic TLS verification request could not be constructed")
			}
			response, requestErr := (&http.Client{Transport: transport}).Do(request)
			if response != nil {
				response.Body.Close()
			}
			// Drain bridge work before checking the origin to exclude a delayed
			// dispatch racing an otherwise correctly rejected HTTP response.
			bridge.close()
			if requestErr == nil || reached.Load() != 0 {
				t.Fatal("untrusted XHTTP TLS peer carried target traffic")
			}
			if protections.Load() == 0 {
				t.Fatal("negative TLS test never attempted the protected physical transport")
			}
		})
	}
}
