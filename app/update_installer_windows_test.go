//go:build windows

package main

import (
	"slices"
	"testing"
)

func TestInstalledUpdateArgumentsAreSilentAndBounded(t *testing.T) {
	arguments := installedUpdateArguments()
	for _, required := range []string{
		"--from-update",
		"/VERYSILENT",
		"/SUPPRESSMSGBOXES",
		"/NORESTART",
		"/CLOSEAPPLICATIONS",
	} {
		if !slices.Contains(arguments, required) {
			t.Fatalf("installed update arguments missing %q: %v", required, arguments)
		}
	}
	for _, forbidden := range []string{"/SILENT", "/FORCECLOSEAPPLICATIONS", "/RESTARTEXITCODE"} {
		if slices.Contains(arguments, forbidden) {
			t.Fatalf("installed update arguments include forbidden %q: %v", forbidden, arguments)
		}
	}
}
