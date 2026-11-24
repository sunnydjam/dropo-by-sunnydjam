//go:build windows

package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// Run only from the disposable Windows client VM. This uses the same GET,
// certificate checks, response limits and issuer validation as the UI.
func TestWindowsLabLauncherEndpoints(t *testing.T) {
	if os.Getenv("COMPUTERNAME") != "DROPO-LAB" || os.Getenv("DROPO_GAME_ROUTING_LAB") != "1" {
		t.Skip("dedicated client lab only")
	}
	client := newQuickCheckHTTPClient(nil)
	defer client.CloseIdleConnections()
	for _, svc := range clientQuickCheckServices {
		if svc.DiscoveryIssuer == "" && svc.Name != "Steam Store" {
			continue
		}
		t.Run(svc.Name, func(t *testing.T) {
			result := invokeQuickCheckURL(context.Background(), client, svc)
			if !result.Success || result.Status != 200 {
				t.Fatalf("HTTP %d: %s", result.Status, result.Error)
			}
			t.Logf("TLS/HTTP %d, %d ms", result.Status, result.TimeMS)
		})
	}
}

// The external lab provides an independent CONNECT exit, reached over the
// private vSwitch. Pin the Moscow DNS answers so both phases exercise the
// very same public IPv4 destinations, even when a CDN rotates its records.
func TestWindowsLabExternalLauncherRoutes(t *testing.T) {
	upstream := os.Getenv("DROPO_LAB_VPN_PROXY")
	if upstream == "" || os.Getenv("COMPUTERNAME") != "DROPO-LAB" || os.Getenv("DROPO_GAME_ROUTING_LAB") != "1" {
		t.Skip("external client lab only")
	}
	proxy, err := net.ResolveTCPAddr("tcp4", upstream)
	if err != nil || !proxy.IP.IsPrivate() {
		t.Fatal("expected private guest proxy")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	var probes []clientQuickCheckService
	const reflector = "api.ipify.org"
	hosts := []string{reflector}
	for _, svc := range clientQuickCheckServices {
		if svc.DiscoveryIssuer != "" || svc.Name == "Steam Store" {
			probes = append(probes, svc)
			u, err := url.Parse(svc.URL)
			if err != nil {
				t.Fatal(err)
			}
			hosts = append(hosts, u.Hostname())
		}
	}
	pinned := map[string]string{}
	var cidrs []string
	for _, host := range hosts {
		ctx, cancel := context.WithTimeout(context.Background(), 7*time.Second)
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
		cancel()
		if err != nil || len(ips) == 0 {
			t.Fatalf("DNS %s: %v", host, err)
		}
		pinned[host] = ips[0].String()
		cidrs = append(cidrs, ips[0].String()+"/32")
	}
	for _, phase := range []struct{ name, expected string }{
		{"underlay", os.Getenv("DROPO_LAB_UNDERLAY_IP")},
		{"tun", os.Getenv("DROPO_LAB_EXIT_IP")},
	} {
		t.Run(phase.name, func(t *testing.T) {
			if phase.name == "tun" {
				startLauncherLabTUN(t, exe, proxy, cidrs)
			}
			client := newQuickCheckHTTPClient(nil)
			defer client.CloseIdleConnections()
			dialer := net.Dialer{Timeout: 5 * time.Second}
			client.Transport.(*http.Transport).DialContext = func(ctx context.Context, _, address string) (net.Conn, error) {
				host, port, err := net.SplitHostPort(address)
				if err != nil {
					return nil, err
				}
				if ip := pinned[host]; ip != "" {
					host = ip
				}
				return dialer.DialContext(ctx, "tcp4", net.JoinHostPort(host, port))
			}
			resp, err := client.Get("https://" + reflector + "/")
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(io.LimitReader(resp.Body, 64))
			resp.Body.Close()
			if err != nil || resp.StatusCode != 200 || strings.TrimSpace(string(body)) != phase.expected {
				t.Fatalf("egress=%q expected=%s status=%d err=%v", body, phase.expected, resp.StatusCode, err)
			}
			t.Logf("external IPv4 %s", phase.expected)
			for _, svc := range probes {
				t.Run(svc.Name, func(t *testing.T) {
					r := invokeQuickCheckURL(context.Background(), client, svc)
					if !r.Success || r.Status != 200 {
						t.Fatalf("HTTP %d: %s", r.Status, r.Error)
					}
					t.Logf("HTTP %d, %d ms", r.Status, r.TimeMS)
				})
			}
		})
	}
}
