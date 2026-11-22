//go:build windows

package wfpguardservice

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"dropo/wfpguard"
	"golang.org/x/sys/windows"
)

func currentUserSID(t *testing.T) string {
	t.Helper()
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &token); err != nil {
		t.Fatal(err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	return user.User.Sid.String()
}

func TestCanonicalUserSID(t *testing.T) {
	valid := currentUserSID(t)
	if got, err := CanonicalUserSID(valid); err != nil || got != valid {
		t.Fatalf("valid SID %q: got %q, %v", valid, got, err)
	}
	for _, invalid := range []string{"", "S-1-5-21-1; (A;;GA;;;WD)", strings.ToLower(valid)} {
		if _, err := CanonicalUserSID(invalid); err == nil {
			t.Fatalf("invalid SID %q accepted", invalid)
		}
	}
}

func TestPipeStatusRoundTripRemainsInactive(t *testing.T) {
	// This runs without SCM or WFP privileges. It checks that a local client
	// using the exact non-instance-creation rights can reach the authenticated
	// request path while the service still reports no protection.
	sid := currentUserSID(t)
	pipeName := fmt.Sprintf(`\\.\pipe\DropoWFPGuard-test-%d-%d`, os.Getpid(), time.Now().UnixNano())
	server, err := newPipeServer(pipeName, sid)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	finished := make(chan error, 1)
	go func() { finished <- server.Run(ctx) }()

	name, _ := windows.UTF16PtrFromString(pipeName)
	client, err := windows.CreateFile(name,
		windows.FILE_READ_DATA|windows.FILE_WRITE_DATA|windows.SYNCHRONIZE,
		0, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		t.Fatalf("open guard pipe with data-only access: %v", err)
	}
	defer windows.CloseHandle(client)
	message := []byte(`{"version":1,"operation":"status"}`)
	var written uint32
	if err := windows.WriteFile(client, message, &written, nil); err != nil || int(written) != len(message) {
		t.Fatalf("write status request: %v, %d bytes", err, written)
	}
	var responseBytes [1024]byte
	var read uint32
	if err := windows.ReadFile(client, responseBytes[:], &read, nil); err != nil {
		t.Fatalf("read status response: %v", err)
	}
	var response Response
	if err := json.Unmarshal(responseBytes[:read], &response); err != nil {
		t.Fatal(err)
	}
	if response.Version != wfpguard.ProtocolVersion || response.ProtectionActive || response.State != "not_integrated" || response.Revision != 0 {
		t.Fatalf("unexpected guard status: %+v", response)
	}
	cancel()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("guard server did not stop")
	}
}
