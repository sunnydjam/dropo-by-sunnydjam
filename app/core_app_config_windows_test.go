//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWindowsAutoStartLauncherNextToResources(t *testing.T) {
	root := t.TempDir()
	resources := filepath.Join(root, ResourcesFolder)
	if err := os.MkdirAll(resources, 0755); err != nil {
		t.Fatalf("create resources: %v", err)
	}
	launcher := filepath.Join(root, AppName+".exe")
	if err := os.WriteFile(launcher, []byte("launcher"), 0644); err != nil {
		t.Fatalf("write launcher: %v", err)
	}

	core := filepath.Join(resources, AppName+"-core.exe")
	if got := resolveWindowsAutoStartLauncherPath(core); got != launcher {
		t.Fatalf("autostart launcher = %q, want %q", got, launcher)
	}
}

func TestWindowsAutoStartKeepsStandaloneExecutable(t *testing.T) {
	exe := filepath.Join(t.TempDir(), AppName+".exe")
	if got := resolveWindowsAutoStartLauncherPath(exe); got != exe {
		t.Fatalf("autostart launcher = %q, want %q", got, exe)
	}
}

func TestWindowsAutoStartCommandUsesWindowsQuoting(t *testing.T) {
	for _, tc := range []struct{ path, command string }{
		{`C:\Program Files\dropo\dropo.exe`, `"C:\Program Files\dropo\dropo.exe" --autostart`},
		{`C:\Users\runneradmin\dropo.exe`, `C:\Users\runneradmin\dropo.exe --autostart`},
		{`D:\Приложения VPN\dropo.exe`, `"D:\Приложения VPN\dropo.exe" --autostart`},
	} {
		if got := windowsAutoStartCommand(tc.path); got != tc.command {
			t.Fatalf("command = %q, want %q", got, tc.command)
		}
	}
}
