package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const managedSidecarCleanupTimeout = 8 * time.Second

const defaultDropoMixedProxyPort = 2088

func (a *App) cleanupManagedSidecarOrphans(reason string) {
	if runtime.GOOS != "windows" || a.basePath == "" {
		return
	}

	paths := a.managedSidecarPaths()
	roots := a.dropoPortableSidecarRoots()
	if len(paths) == 0 && len(roots) == 0 {
		return
	}

	protectedPID, _ := a.protectedRouter.status()
	killed, err := killWindowsDropoManagedSidecars(paths, roots, protectedPID)
	if err != nil {
		a.writeLog(fmt.Sprintf("[Cleanup] failed to scan managed sidecar processes (%s): %v", reason, err))
		return
	}
	if len(killed) > 0 {
		a.writeLog(fmt.Sprintf("[Cleanup] stopped orphaned managed sidecar process(es) (%s): %v", reason, killed))
	}
}

func (a *App) cleanupOwnedWinDivertService(reason string) {
	if a == nil || runtime.GOOS != "windows" || a.basePath == "" {
		return
	}
	roots := a.dropoPortableSidecarRoots()
	basePath, err := filepath.Abs(a.basePath)
	if err != nil {
		basePath = a.basePath
	}
	basePath = filepath.Clean(basePath)

	seen := map[string]bool{}
	for _, root := range roots {
		seen[strings.ToLower(filepath.Clean(root))] = true
	}
	if !seen[strings.ToLower(basePath)] {
		roots = append(roots, basePath)
	}
	if runtimeBase := a.runtimeBasePath(); runtimeBase != "" {
		if abs, err := filepath.Abs(runtimeBase); err == nil && !seen[strings.ToLower(filepath.Clean(abs))] {
			roots = append(roots, filepath.Clean(abs))
		}
	}
	cleanupWinDivertServiceIfOwned(roots, reason, func(message string) {
		a.writeLog("[Cleanup] " + message)
	})
}

func (a *App) cleanupDropoRuntimeResidue(reason string) {
	if a == nil {
		return
	}
	a.resetDropoSystemProxy(reason)
	a.cleanupManagedSidecarOrphans(reason)
	a.cleanupOwnedWinDivertService(reason)
}

func (a *App) resetDropoSystemProxy(reason string) {
	if a == nil || runtime.GOOS != "windows" {
		return
	}
	changed, current, err := resetStaleDropoPAC()
	if err != nil {
		a.writeLog(fmt.Sprintf("[Cleanup] system proxy reset failed (%s): %v", reason, err))
		return
	}
	if changed {
		a.writeLog(fmt.Sprintf("[Cleanup] system proxy reset (%s): removed dropo proxy %q", reason, current))
	}
}

func (a *App) managedSidecarPaths() []string {
	basePath, err := filepath.Abs(a.runtimeBasePath())
	if err != nil {
		basePath = a.runtimeBasePath()
	}

	candidates := []string{
		a.singBoxPathSnapshot(),
		filepath.Join(a.binDir(), ByeDPIProcessName),
		filepath.Join(a.binDir(), ZapretProcessName),
		filepath.Join(a.binDir(), XrayExeName),
		filepath.Join(a.binDir(), TgWsProxyProcessName),
	}

	seen := map[string]bool{}
	paths := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		abs, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		if !pathIsInside(abs, basePath) || seen[strings.ToLower(abs)] || !fileExists(abs) {
			continue
		}
		seen[strings.ToLower(abs)] = true
		paths = append(paths, abs)
	}
	return paths
}

func (a *App) dropoPortableSidecarRoots() []string {
	basePath, err := filepath.Abs(a.basePath)
	if err != nil {
		basePath = a.basePath
	}
	basePath = filepath.Clean(basePath)

	seen := map[string]bool{}
	addRoot := func(path string, roots *[]string) {
		if path == "" {
			return
		}
		abs, err := filepath.Abs(path)
		if err != nil {
			return
		}
		abs = filepath.Clean(abs)
		key := strings.ToLower(abs)
		if seen[key] || !looksLikeDropoPortableRoot(abs) {
			return
		}
		if !hasManagedSidecarBin(abs) {
			return
		}
		seen[key] = true
		*roots = append(*roots, abs)
	}

	roots := []string{}
	addRoot(basePath, &roots)

	parent := filepath.Dir(basePath)
	entries, err := os.ReadDir(parent)
	if err != nil {
		return roots
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := strings.ToLower(entry.Name())
		if !strings.HasPrefix(name, "dropo-") {
			continue
		}
		addRoot(filepath.Join(parent, entry.Name()), &roots)
	}
	return roots
}

func looksLikeDropoPortableRoot(path string) bool {
	name := strings.ToLower(filepath.Base(filepath.Clean(path)))
	return name == "dropo" || strings.HasPrefix(name, "dropo-")
}

func hasManagedSidecarBin(root string) bool {
	for _, name := range []string{ByeDPIProcessName, ZapretProcessName, XrayExeName, TgWsProxyProcessName, "sing-box.exe"} {
		if fileExists(filepath.Join(root, "bin", name)) {
			return true
		}
	}
	return false
}

func pathIsInside(path, basePath string) bool {
	path = filepath.Clean(path)
	basePath = filepath.Clean(basePath)
	if strings.EqualFold(path, basePath) {
		return true
	}
	baseWithSeparator := basePath
	if !strings.HasSuffix(baseWithSeparator, string(filepath.Separator)) {
		baseWithSeparator += string(filepath.Separator)
	}
	return strings.HasPrefix(strings.ToLower(path), strings.ToLower(baseWithSeparator))
}

func killWindowsDropoManagedSidecars(paths []string, roots []string, excludedPID int) ([]int, error) {
	if runtime.GOOS != "windows" || len(paths) == 0 && len(roots) == 0 {
		return nil, nil
	}
	return killWindowsDropoManagedSidecarsNative(paths, roots, excludedPID)
}

// killWindowsDropoManagedSidecarsPowerShell remains as a non-runtime fallback
// reference. The normal cleanup path enumerates and terminates owned processes
// with Win32 APIs and therefore does not trigger a PowerShell/taskkill chain.
func killWindowsDropoManagedSidecarsPowerShell(paths []string, roots []string) ([]int, error) {
	if len(paths) == 0 && len(roots) == 0 {
		return nil, nil
	}

	quoted := make([]string, 0, len(paths))
	for _, path := range paths {
		quoted = append(quoted, "'"+strings.ReplaceAll(path, "'", "''")+"'")
	}
	quotedRoots := make([]string, 0, len(roots))
	for _, root := range roots {
		quotedRoots = append(quotedRoots, "'"+strings.ReplaceAll(root, "'", "''")+"'")
	}

	script := fmt.Sprintf(`
$paths = @(%s)
$roots = @(%s)
$names = @('sing-box', 'ciadpi', 'winws2', 'xray', 'tg-ws-proxy')
function Test-InsidePath($path, $root) {
  if (-not $path -or -not $root) { return $false }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($path)
    $fullRoot = [System.IO.Path]::GetFullPath($root)
  } catch {
    return $false
  }
  if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  if (-not $fullRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $fullRoot += [System.IO.Path]::DirectorySeparatorChar
  }
  return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}
$procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
  if (-not ($names -contains $_.ProcessName)) { return $false }
  $exePath = $_.Path
  if (-not $exePath) { return $false }
  if ($paths -contains $exePath) { return $true }
  foreach ($root in $roots) {
    if (Test-InsidePath $exePath (Join-Path $root 'bin')) { return $true }
  }
  return $false
}
foreach ($p in $procs) {
  Write-Output $p.Id
  & taskkill.exe /F /T /PID $p.Id | Out-Null
}
`, strings.Join(quoted, ","), strings.Join(quotedRoots, ","))

	ctx, cancel := context.WithTimeout(context.Background(), managedSidecarCleanupTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script)
	configureBackgroundCommand(cmd)
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Errorf("cleanup timed out after %s", managedSidecarCleanupTimeout)
	}
	if err != nil {
		return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(string(output)))
	}

	pids := make([]int, 0)
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		pid, err := strconv.Atoi(line)
		if err == nil {
			pids = append(pids, pid)
		}
	}
	return pids, nil
}

func waitForProcessDone(done <-chan error, timeout time.Duration) bool {
	if done == nil {
		return true
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-done:
		return true
	case <-timer.C:
		return false
	}
}

func runBackgroundCommandWithTimeout(timeout time.Duration, name string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	configureBackgroundCommand(cmd)
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("%s timed out after %s", name, timeout)
	}
	return err
}
