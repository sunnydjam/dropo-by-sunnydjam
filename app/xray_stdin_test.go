package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestXrayRuntimeUsesStdinWithoutCredentialFile(t *testing.T) {
	binary := os.Getenv("DROPO_XRAY_FIXTURE_BINARY")
	if binary == "" {
		t.Skip("official fixture runtime not configured")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	directory := t.TempDir()
	payload, err := json.Marshal(map[string]any{"log": map[string]string{"loglevel": "none"}, "inbounds": []any{map[string]any{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": map[string]string{"auth": "noauth"}}}, "outbounds": []any{map[string]string{"protocol": "blackhole"}}})
	if err != nil {
		t.Fatal(err)
	}
	manager := NewXrayBridgeManager(directory, directory, nil)
	manager.exePath = binary
	if err = manager.Start(payload); err != nil {
		t.Fatal(err)
	}
	defer manager.Stop()
	socket, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", fmt.Sprint(port)))
	if err != nil {
		t.Fatal(err)
	}
	socket.Close()
	if _, err = os.Stat(filepath.Join(directory, XrayBridgeConfigFileName)); !os.IsNotExist(err) {
		t.Fatal("runtime materialized a plaintext configuration")
	}
	manager.mu.Lock()
	args := append([]string(nil), manager.cmd.Args...)
	manager.mu.Unlock()
	if len(args) != 4 || args[3] != "stdin:" {
		t.Fatal("runtime does not consume its configuration through stdin")
	}
}
