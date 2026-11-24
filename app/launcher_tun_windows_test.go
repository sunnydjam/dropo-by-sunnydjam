//go:build windows

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

const launcherLabDestination = "198.51.100.42:80"

// The only route installed by this fixture is a documentation /32. A real
// sing-box TUN applies Dropo's full-mode routing rules to all five clients.
func TestWindowsLabLauncherTUN(t *testing.T) {
	if os.Getenv("DROPO_GAME_ROUTING_LAB") != "1" || os.Getenv("COMPUTERNAME") != "DROPO-LAB" {
		t.Skip("dedicated client lab only")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// The test exit accepts HTTP CONNECT only. Echoing the received Host
	// confirms both the route and delivery of each launcher's own request.
	exit := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect {
			http.Error(w, "expected CONNECT", http.StatusBadRequest)
			return
		}
		conn, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(8 * time.Second))
		fmt.Fprint(rw, "HTTP/1.1 200 Connection established\r\n\r\n")
		if err := rw.Flush(); err != nil {
			return
		}
		request, err := http.ReadRequest(rw.Reader)
		if err == nil {
			defer request.Body.Close()
			fmt.Fprintf(conn, "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(request.Host), request.Host)
		}
	}))
	defer exit.Close()
	startLauncherLabTUN(t, exe, exit.Listener.Addr().(*net.TCPAddr), []string{"198.51.100.42/32"})
	stage := t.TempDir()
	for _, client := range []struct{ exe, host string }{
		{"steamwebhelper.exe", "store.steampowered.com"},
		{"EADesktop.exe", "accounts.ea.com"},
		{"EpicGamesLauncher.exe", "api.epicgames.dev"},
		{"Battle.net.exe", "oauth.battle.net"},
		{"RiotClientServices.exe", "auth.riotgames.com"},
	} {
		t.Run(client.exe, func(t *testing.T) {
			path := filepath.Join(stage, client.exe)
			if err := os.Link(exe, path); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			child := exec.CommandContext(ctx, path, "-test.run=^TestWindowsLabLauncherHTTPRequest$")
			child.Env = append(os.Environ(), "DROPO_LAB_HTTP_HOST="+client.host)
			if out, err := child.CombinedOutput(); err != nil {
				t.Fatalf("%v: %s", err, out)
			}
		})
	}
}

func TestWindowsLabLauncherHTTPRequest(t *testing.T) {
	host := os.Getenv("DROPO_LAB_HTTP_HOST")
	if host == "" || os.Getenv("DROPO_GAME_ROUTING_LAB") != "1" || os.Getenv("COMPUTERNAME") != "DROPO-LAB" {
		t.Skip("dedicated launcher fixture only")
	}
	c, err := net.DialTimeout("tcp4", launcherLabDestination, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := fmt.Fprintf(c, "GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", host); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 256))
	if err != nil || response.StatusCode != http.StatusOK || string(body) != host {
		t.Fatalf("missing proxy echo for %s: status=%d err=%v", host, response.StatusCode, err)
	}
}

func startLauncherLabTUN(t *testing.T, exe string, proxy *net.TCPAddr, cidrs []string) {
	t.Helper()
	const adapter = "DropoLauncherQA"
	if _, err := net.InterfaceByName(adapter); err == nil {
		t.Fatal("fixture adapter already exists")
	}
	route := map[string]any{"auto_detect_interface": true}
	(&ConfigBuilderForStorage{}).applyAllTrafficMode(route)
	config := map[string]any{
		"inbounds": []any{map[string]any{"type": "tun", "interface_name": adapter, "address": []string{"172.30.254.1/30"},
			"auto_route": true, "route_address": cidrs, "stack": "system"}},
		"outbounds": []any{map[string]any{"type": "direct", "tag": "direct"}, map[string]any{"type": "http", "tag": "proxy",
			"server": proxy.IP.String(), "server_port": proxy.Port}},
		"route": route,
	}
	stage := t.TempDir()
	file := filepath.Join(stage, "tun.json")
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(filepath.Join(filepath.Dir(exe), "sing-box.exe"), "run", "-c", file)
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := net.InterfaceByName(adapter); err != nil {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Error("fixture TUN adapter survived process exit")
	})
	deadline := time.Now().Add(10 * time.Second)
	var lastPending string
	for {
		if iface, err := net.InterfaceByName(adapter); err == nil && iface.Flags&net.FlagUp != 0 {
			lastPending = ""
			for _, cidr := range cidrs {
				ip := netip.MustParsePrefix(cidr).Addr().As4()
				var index uint32
				if err := windows.GetBestInterfaceEx(&windows.SockaddrInet4{Addr: ip}, &index); err != nil || int(index) != iface.Index {
					lastPending = cidr
					break
				}
			}
			if lastPending == "" {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("Windows did not activate TUN routes; pending %q", lastPending)
		}
		time.Sleep(100 * time.Millisecond)
	}
}
