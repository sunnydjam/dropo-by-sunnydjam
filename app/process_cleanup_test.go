package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManagedSidecarPathsIncludesTelegramProxy(t *testing.T) {
	basePath := t.TempDir()
	binPath := filepath.Join(basePath, "bin")
	if err := os.MkdirAll(binPath, 0755); err != nil {
		t.Fatalf("create bin dir failed: %v", err)
	}
	tgProxyPath := filepath.Join(binPath, TgWsProxyProcessName)
	if err := os.WriteFile(tgProxyPath, []byte("test"), 0644); err != nil {
		t.Fatalf("write tg-ws-proxy placeholder failed: %v", err)
	}

	app := &App{basePath: basePath}
	paths := app.managedSidecarPaths()
	if !containsStringFold(paths, tgProxyPath) {
		t.Fatalf("managed sidecar paths = %v, want %s", paths, tgProxyPath)
	}
}

func containsStringFold(values []string, want string) bool {
	for _, value := range values {
		if strings.EqualFold(filepath.Clean(value), filepath.Clean(want)) {
			return true
		}
	}
	return false
}
