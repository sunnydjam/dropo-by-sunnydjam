//go:build windows

package main

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

func TestInstallerRelaunchesOnlyUpdatedLauncherWithoutFinishPage(t *testing.T) {
	contents, err := os.ReadFile(filepath.Join("..", "packaging", "windows", "dropo.iss"))
	if err != nil {
		t.Fatal(err)
	}
	script := strings.ReplaceAll(string(contents), "\r\n", "\n")
	if !strings.Contains(script, "RestartApplications=no") {
		t.Fatal("Restart Manager must not race the explicit updater relaunch")
	}
	run := strings.Split(strings.Split(script, "[Run]\n")[1], "[UninstallRun]")[0]
	var automatic, interactive int
	for _, line := range strings.Split(run, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "Filename:") {
			continue
		}
		if strings.Contains(strings.ToLower(line), "explorer.exe") {
			t.Fatal("updater relaunch must not delegate executable activation to Explorer")
		}
		if !strings.Contains(line, `Filename: "{app}\dropo.exe"`) {
			continue
		}
		if regexp.MustCompile(`Check:\s*IsFromUpdate\s*$`).MatchString(line) {
			automatic++
			for _, forbidden := range []string{"postinstall", "skipifsilent", "unchecked", "runhidden", "--autostart"} {
				if strings.Contains(line, forbidden) {
					t.Fatalf("automatic relaunch must open without user interaction: %s", line)
				}
			}
			for _, required := range []string{`WorkingDir: "{app}"`, "nowait", "runasoriginaluser"} {
				if !strings.Contains(line, required) {
					t.Fatalf("automatic relaunch missing %q: %s", required, line)
				}
			}
		} else if strings.Contains(line, "Check: not IsFromUpdate") && strings.Contains(line, "postinstall skipifsilent") {
			interactive++
		} else {
			t.Fatalf("unexpected additional launcher entry: %s", line)
		}
	}
	if automatic != 1 || interactive != 1 {
		t.Fatalf("expected mutually exclusive automatic/interactive launch entries, got %d/%d", automatic, interactive)
	}
}

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
