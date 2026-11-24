//go:build windows

package trafficorchestrator

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Runs only inside the dedicated VM. DNS and the echo origin are local fixtures.
func TestWindowsSelectiveGameSocket(t *testing.T) {
	if os.Getenv("DROPO_GAME_ROUTING_LAB") != "1" || os.Getenv("COMPUTERNAME") != "DROPO-LAB" {
		t.Skip("dedicated client lab only")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	plan := fakeIPTestPlan()
	externalProxy := os.Getenv("DROPO_LAB_VPN_PROXY")
	const reflector = "api.ipify.org"
	if externalProxy != "" {
		plan.Services[0].ExactHosts = []string{reflector}
	}
	plan.DirectRules = []DirectRule{{ID: "game-direct", ProcessNames: []string{filepath.Base(exe), "steamwebhelper.exe", "RiotClientServices.exe"}}}
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	registry := NewTCPRedirectRegistry()
	type observation struct {
		route ServiceRouteKind
		owner string
	}
	seen := make(chan observation, 1)
	relay, err := StartTCPRelayWithDialer(registry, func(ctx context.Context, target TCPRedirectTarget) (net.Conn, error) {
		if externalProxy != "" && target.Host == reflector && target.Flow.DestinationPort == 443 {
			switch target.Route {
			case ServiceRouteDirect:
				return DialRetiredFakeHost(ctx, "tcp4", reflector, 443)
			case ServiceRouteVPN:
				return dialLabHTTPSExit(ctx, externalProxy, reflector)
			}
		}
		if target.Host != "www.youtube.com" {
			return nil, fmt.Errorf("unexpected target %+v", target)
		}
		owner := NewWindowsFlowIdentityResolver().ResolveProcessName(target.Flow)
		select {
		case seen <- observation{target.Route, owner}:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		client, server := net.Pipe()
		go func() { defer server.Close(); _, _ = io.Copy(server, server) }()
		return client, nil
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	redirect, err := NewTCPPacketRedirector(registry, relay.Port())
	if err != nil {
		t.Fatal(err)
	}
	proxy, udpTargets := startUDPEchoSOCKS(t, 2)
	udpRegistry := NewUDPRedirectRegistry()
	udpRelay, err := StartUDPRelay(udpRegistry, proxy, relay.Port(), func(s string) { t.Log(s) })
	if err != nil {
		t.Fatal(err)
	}
	defer udpRelay.Close()
	udpRedirect, err := NewUDPPacketRedirector(udpRegistry, relay.Port())
	if err != nil {
		t.Fatal(err)
	}
	p, err := NewProcessorWithFullSelectiveRuntime(plan, NewWindowsFlowIdentityResolver(), redirect, udpRedirect, directory)
	if err != nil {
		t.Fatal(err)
	}
	filter, err := BuildSelectiveWinDivertFilterForMode(nil, relay.Port(), false)
	if err != nil {
		t.Fatal(err)
	}
	driver, err := OpenSelectiveWinDivertBackend(filepath.Join(filepath.Dir(exe), "WinDivert.dll"), filter, relay.Port())
	if err != nil {
		t.Fatal(err)
	}
	other, secondErr := OpenWinDivertBackendWithFilter(filepath.Join(filepath.Dir(exe), "WinDivert.dll"), filter)
	if secondErr == nil {
		other.Close()
		driver.Close()
		t.Fatal("selective backend admitted a second WinDivert owner")
	}
	engine, err := NewEngine(driver, p, nil)
	if err != nil {
		driver.Close()
		t.Fatal(err)
	}
	if err := engine.Start(); err != nil {
		driver.Close()
		t.Fatal(err)
	}
	defer func() {
		if err := engine.Stop(); err != nil {
			t.Error(err)
		}
	}()
	dns, err := net.DialTimeout("udp4", "192.0.2.53:53", 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer dns.Close()
	dns.SetDeadline(time.Now().Add(5 * time.Second))
	query := testDNSQueryPacket(t, "www.youtube.com", dnsTypeA)[28:]
	if _, err = dns.Write(query); err != nil {
		t.Fatal(err)
	}
	answer := make([]byte, 512)
	n, err := dns.Read(answer)
	if err != nil {
		t.Fatal(err)
	}
	target, ok := directory.ResolveHost("www.youtube.com")
	if !ok || n < 16 || !bytes.Equal(answer[n-4:n], target.Address.AsSlice()) {
		t.Fatalf("unexpected DNS answer, length %d", n)
	}
	c, err := net.DialTimeout("tcp4", net.JoinHostPort(target.Address.String(), "443"), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	u, err := net.Dial("udp4", net.JoinHostPort(target.Address.String(), "443"))
	if err != nil {
		t.Fatal(err)
	}
	defer u.Close()
	var externalAlias string
	if externalProxy != "" {
		entry, ok := directory.ResolveHost(reflector)
		if !ok {
			t.Fatal("missing test egress alias")
		}
		externalAlias = net.JoinHostPort(entry.Address.String(), "443")
	}
	stage := t.TempDir()
	for _, client := range launcherFixtures {
		if err := os.Link(exe, filepath.Join(stage, client.name)); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 2; i++ {
		c.SetDeadline(time.Now().Add(5 * time.Second))
		msg := []byte("dropo-game-echo")
		if _, err := c.Write(msg); err != nil {
			t.Fatal(err)
		}
		back := make([]byte, len(msg))
		if _, err := io.ReadFull(c, back); err != nil || !bytes.Equal(back, msg) {
			t.Fatalf("echo %d: %v", i, err)
		}
		u.SetDeadline(time.Now().Add(5 * time.Second))
		if _, err := u.Write(msg); err != nil {
			t.Fatal(err)
		}
		n, err := u.Read(back)
		if err != nil || !bytes.Equal(back[:n], msg) {
			t.Fatalf("UDP echo %d: %v", i, err)
		}
		select {
		case dst := <-udpTargets:
			if dst != "www.youtube.com:443" {
				t.Fatalf("wrong UDP exit %s", dst)
			}
		case <-time.After(time.Second):
			t.Fatal("no UDP SOCKS destination observed")
		}
		if i == 0 {
			initial := <-seen
			if initial.route != ServiceRouteVPN {
				t.Fatalf("initial connection used %s", initial.route)
			}
		}
		// Keep the original TCP/UDP sockets open throughout both revisions.
		// Each child creates a fresh socket to the same cached DNS address.
		for _, client := range launcherFixtures {
			name := client.name
			t.Run(string(plan.Routes[0].Kind)+"/"+name, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
				defer cancel()
				cmd := exec.CommandContext(ctx, filepath.Join(stage, name), "-test.run=^TestLabLauncherClient$")
				cmd.Env = append(os.Environ(), "DROPO_LAB_GAME_TARGET="+c.RemoteAddr().String())
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("launcher fixture: %v %s", err, out)
				}
				select {
				case got := <-seen:
					if got.route != plan.Routes[0].Kind || !strings.EqualFold(got.owner, name) {
						t.Fatalf("route=%s owner=%q", got.route, got.owner)
					}
				case <-ctx.Done():
					t.Fatal("no terminal relay observation")
				}
			})
		}
		if externalAlias != "" {
			want := os.Getenv("DROPO_LAB_EXIT_IP")
			if i == 1 {
				want = os.Getenv("DROPO_LAB_UNDERLAY_IP")
			}
			transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp4", externalAlias)
			}}
			client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
			resp, err := client.Get("https://" + reflector + "/")
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(io.LimitReader(resp.Body, 64))
			resp.Body.Close()
			transport.CloseIdleConnections()
			if err != nil || resp.StatusCode != 200 || strings.TrimSpace(string(body)) != want {
				t.Fatalf("selective %s exit=%q, want %s", plan.Routes[0].Kind, body, want)
			}
			t.Logf("selective %s external IPv4 %s", plan.Routes[0].Kind, want)
		}
		if i == 0 {
			plan.Revision++
			plan.Routes[0].Kind = ServiceRouteDirect
			if err := engine.ApplyPlan(plan); err != nil {
				t.Fatal(err)
			}
		}
	}
	t.Logf("DNS reply, TCP and UDP echo on established sockets across policy change passed; captured=%d", engine.Stats().CapturedPackets)
}

// Lab substitution for the subscription exit. Windows still classifies the
// socket, reflects it and selects its terminal route in the normal processor.
func dialLabHTTPSExit(ctx context.Context, proxy, host string) (net.Conn, error) {
	addr, err := net.ResolveTCPAddr("tcp4", proxy)
	if err != nil || !addr.IP.IsPrivate() {
		return nil, fmt.Errorf("expected private lab exit")
	}
	conn, err := (&net.Dialer{Timeout: 6 * time.Second}).DialContext(ctx, "tcp4", proxy)
	if err != nil {
		return nil, err
	}
	conn.SetDeadline(time.Now().Add(6 * time.Second))
	if _, err := fmt.Fprintf(conn, "CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n", host, host); err != nil {
		conn.Close()
		return nil, err
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodConnect})
	if err != nil {
		conn.Close()
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		conn.Close()
		return nil, fmt.Errorf("CONNECT returned %d", resp.StatusCode)
	}
	conn.SetDeadline(time.Time{})
	return conn, nil
}

func TestLabLauncherClient(t *testing.T) {
	addr := os.Getenv("DROPO_LAB_GAME_TARGET")
	if addr == "" || os.Getenv("COMPUTERNAME") != "DROPO-LAB" || os.Getenv("DROPO_GAME_ROUTING_LAB") != "1" {
		t.Skip("dedicated launcher fixture only")
	}
	conn, err := net.DialTimeout("tcp4", addr, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(4 * time.Second))
	payload := []byte(filepath.Base(os.Args[0]))
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, reply); err != nil || !bytes.Equal(reply, payload) {
		t.Fatalf("invalid launcher echo: %v", err)
	}
}
