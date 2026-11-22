//go:build windows

package main

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWindowsExternalVPNProbeDetectsZapretProcess(t *testing.T) {
	testWindowsExternalVPNProcessFixture(t, "winws2.exe", "DPI bypass process")
}

func TestWindowsExternalVPNProbeDetectsV2RayTunProcess(t *testing.T) {
	testWindowsExternalVPNProcessFixture(t, "v2RayTun.exe", "VPN process")
}

func testWindowsExternalVPNProcessFixture(t *testing.T, executableName, expectedKind string) {
	t.Helper()
	powershell, err := exec.LookPath("powershell")
	if err != nil {
		t.Skip("PowerShell is unavailable")
	}

	fixture := filepath.Join(t.TempDir(), executableName)
	source, err := os.Open(powershell)
	if err != nil {
		t.Fatalf("open PowerShell fixture source: %v", err)
	}
	destination, err := os.Create(fixture)
	if err != nil {
		_ = source.Close()
		t.Fatalf("create winws2 fixture: %v", err)
	}
	if _, err := io.Copy(destination, source); err != nil {
		_ = source.Close()
		_ = destination.Close()
		t.Fatalf("copy winws2 fixture: %v", err)
	}
	_ = source.Close()
	if err := destination.Close(); err != nil {
		t.Fatalf("close winws2 fixture: %v", err)
	}

	cmd := exec.Command(fixture, "-NoProfile", "-Command", "Start-Sleep -Seconds 60")
	configureBackgroundCommand(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start winws2 fixture: %v", err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	}()

	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		conflicts, probeErr := detectExternalVPNConflicts()
		if probeErr == nil {
			for _, conflict := range conflicts {
				if strings.EqualFold(conflict.Name, executableName) && conflict.Kind == expectedKind {
					return
				}
			}
		}
		time.Sleep(150 * time.Millisecond)
	}
	t.Fatalf("external VPN preflight did not report the running %s process", executableName)
}
