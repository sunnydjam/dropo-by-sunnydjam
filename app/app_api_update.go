package main

// Update methods for dropo.
// Checking, preparing a download, and starting installation are separate.

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

func (a *App) NotifyUpdateAvailable(version string) map[string]interface{} {
	a.waitForInit()
	allowed := a.storage != nil && a.storage.GetAppSettings().Notifications &&
		len(version) <= 64 && !strings.ContainsAny(version, "\x00\r\n")
	return map[string]interface{}{"success": true, "shown": allowed && showSystemNotice(
		"Доступно обновление Dropo", "Вышла новая версия "+version+". Откройте Dropo, чтобы обновить приложение.")}
}

func (a *App) DownloadUpdateOnly(reveal bool) map[string]interface{} {
	a.waitForInit()
	if !a.updateInProgress.CompareAndSwap(false, true) {
		return map[string]interface{}{"success": false, "error": "Обновление уже загружается"}
	}
	defer a.updateInProgress.Store(false)
	info, err := CheckForUpdates()
	if err != nil || !info.Available {
		return map[string]interface{}{"success": false, "error": "Не удалось подтвердить наличие обновления"}
	}
	path, err := a.prepareUpdateDownload(info)
	if err != nil {
		return map[string]interface{}{"success": false, "error": err.Error()}
	}
	if reveal {
		openFolder(filepath.Dir(path))
	}
	return map[string]interface{}{"success": true, "downloaded": true, "version": info.Version}
}

func (a *App) prepareUpdateDownload(info *UpdateInfo) (string, error) {
	if err := validateTrustedUpdateURL(info.DownloadURL); err != nil {
		return "", err
	}
	if a.storage == nil {
		return "", fmt.Errorf("хранилище настроек недоступно")
	}
	directory := filepath.Join(a.storage.GetResourcesPath(), "update-downloads")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return "", err
	}
	target := filepath.Join(directory, "dropo-update"+updateFileExtension(info.DownloadURL))
	if verifyFileSHA256AndSize(target, info.SHA256, info.FileSize) == nil {
		return target, nil
	}
	a.emitEvent("update-stage", map[string]interface{}{"stage": "downloading"})
	var lastProgress time.Time
	path, err := DownloadUpdate(info.DownloadURL, info.FileSize, info.SHA256, func(done, total int64) {
		if done == total || time.Since(lastProgress) >= 200*time.Millisecond {
			lastProgress = time.Now()
			a.emitEvent("update-progress", map[string]interface{}{
				"downloaded": done, "total": total, "percent": float64(done) / float64(total) * 100,
			})
		}
	})
	if err != nil {
		return "", err
	}
	defer os.Remove(path)
	input, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer input.Close()
	output, err := os.CreateTemp(directory, ".download-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(output.Name())
	_, copyErr := io.Copy(output, input)
	closeErr := output.Close()
	if copyErr != nil {
		return "", copyErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	if err := verifyFileSHA256AndSize(output.Name(), info.SHA256, info.FileSize); err != nil {
		return "", err
	}
	if err := os.Rename(output.Name(), target); err != nil {
		return "", err
	}
	return target, nil
}

// CheckForUpdates проверяет наличие обновлений (API для фронтенда)
func (a *App) CheckForUpdates() map[string]interface{} {
	updateInfo, err := CheckForUpdates()
	if err != nil {
		return map[string]interface{}{
			"success": false,
			"error":   err.Error(),
		}
	}

	return map[string]interface{}{
		"success":          true,
		"hasUpdate":        updateInfo.Available,
		"currentVersion":   updateInfo.CurrentVersion,
		"latestVersion":    updateInfo.Version,
		"downloadURL":      updateInfo.DownloadURL,
		"releaseNotes":     updateInfo.Description,
		"publishedAt":      updateInfo.PublishedAt,
		"releaseURL":       updateInfo.ReleaseURL,
		"fileSize":         updateInfo.FileSize,
		"assetName":        updateInfo.AssetName,
		"platform":         CurrentPlatformTarget().ReleaseOS,
		"selfUpdate":       runtime.GOOS == "windows" && updateInfo.DistributionMode == distributionModeInstalled,
		"distributionMode": updateInfo.DistributionMode,
	}
}

// DownloadAndInstallUpdate downloads and installs only after the user confirms
// the action in the trusted UI. CheckForUpdates never invokes this method.
func (a *App) DownloadAndInstallUpdate() map[string]interface{} {
	if !a.updateInProgress.CompareAndSwap(false, true) {
		return map[string]interface{}{"success": false, "error": "Обновление уже выполняется"}
	}
	installerStarted := false
	defer func() {
		if !installerStarted {
			a.updateInProgress.Store(false)
		}
	}()
	stage := func(value string) {
		a.emitEvent("update-stage", map[string]interface{}{"stage": value})
	}
	if runtime.GOOS != "windows" || currentDistributionMode() != distributionModeInstalled {
		return map[string]interface{}{
			"success": false,
			"error":   "Self-update is not implemented for " + CurrentPlatformTarget().ReleaseOS,
		}
	}
	stage("checking")
	updateInfo, err := CheckForUpdates()
	if err != nil {
		return map[string]interface{}{"success": false, "error": "Failed to resolve update: " + err.Error()}
	}
	if !updateInfo.Available {
		return map[string]interface{}{"success": false, "error": "No update is available"}
	}
	tempFile, err := a.prepareUpdateDownload(updateInfo)

	if err != nil {
		a.AddToLogBuffer("Update download failed: " + err.Error())
		return map[string]interface{}{
			"success": false,
			"error":   "Failed to download update: " + err.Error(),
		}
	}

	a.AddToLogBuffer("Update downloaded to: " + tempFile)
	stage("verifying")

	stagedFile, err := stageInstalledUpdate(tempFile, updateInfo.Version, updateInfo.FileSize, updateInfo.SHA256)
	if err != nil {
		_ = os.Remove(tempFile)
		return map[string]interface{}{
			"success": false,
			"error":   "Failed to stage installer securely: " + err.Error(),
		}
	}

	// Keep the current route alive until the complete installer has been
	// downloaded, size-checked, hashed and moved into protected storage. Users
	// who need Dropo to reach GitHub would otherwise lose the update transport
	// before the first byte was downloaded.
	if a.isVPNRunning() {
		stage("stopping")
		a.Stop()
	}
	stage("installing")
	if err := startInstalledUpdate(stagedFile, updateInfo.FileSize, updateInfo.SHA256); err != nil {
		return map[string]interface{}{
			"success": false,
			"error":   "Failed to start installer: " + err.Error(),
		}
	}

	a.AddToLogBuffer("Update installer started; the current app will close...")
	installerStarted = true

	// Quit the app
	go func() {
		time.Sleep(500 * time.Millisecond)
		a.FinalizeQuit()
	}()

	return map[string]interface{}{
		"success": true,
		"message": "Update downloaded, app will restart",
		"version": updateInfo.Version,
	}
}

func resolvePortableInstallRoot(execDir string) (string, string) {
	clean := filepath.Clean(execDir)
	if strings.EqualFold(filepath.Base(clean), "resources") {
		root := filepath.Dir(clean)
		return root, filepath.Join(root, "dropo.exe")
	}
	if strings.EqualFold(filepath.Base(clean), "app") &&
		strings.EqualFold(filepath.Base(filepath.Dir(clean)), "resources") {
		root := filepath.Dir(filepath.Dir(clean))
		return root, filepath.Join(root, "dropo.exe")
	}
	return clean, filepath.Join(clean, "dropo.exe")
}

func makeUpdateScript(tempFile, execPath, execDir string) (string, string, error) {
	// Place the script in a fresh private directory (0700) with a random name so
	// another local process cannot pre-create or swap the script between our write
	// and the elevated launch (TOCTOU → arbitrary code execution). See review.md §4.
	scriptDir, err := os.MkdirTemp("", "dropo-update-*")
	if err != nil {
		return "", "", fmt.Errorf("failed to create private update dir: %w", err)
	}
	_ = os.Chmod(scriptDir, 0700)
	return renderUpdateScript(scriptDir, tempFile, execPath, execDir, "")
}

func makeProtectedUpdateScript(tempFile, execPath, execDir, expectedSHA256 string) (string, string, error) {
	if normalizeGitHubSHA256(expectedSHA256) == "" {
		return "", "", fmt.Errorf("release asset has no valid SHA-256 digest")
	}
	root, err := prepareProtectedRuntime("updates")
	if err != nil {
		return "", "", err
	}
	scriptDir, err := os.MkdirTemp(root, "update-*")
	if err != nil {
		return "", "", err
	}
	return renderUpdateScript(scriptDir, tempFile, execPath, execDir, expectedSHA256)
}

func renderUpdateScript(scriptDir, tempFile, execPath, execDir, expectedSHA256 string) (string, string, error) {
	expectedSHA256 = normalizeGitHubSHA256(expectedSHA256)
	hashCheck := ""
	if expectedSHA256 != "" {
		hashCheck = fmt.Sprintf("$actualHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()\nif ($actualHash -ne %s) { throw 'Update SHA-256 mismatch' }\n", psQuote(expectedSHA256))
	}

	switch strings.ToLower(filepath.Ext(tempFile)) {
	case ".exe":
		updateScript := filepath.Join(scriptDir, "dropo_update.ps1")
		scriptContent := fmt.Sprintf(`$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 2
$package = %s
%s
$process = Start-Process -FilePath $package -ArgumentList @("--from-update", "/SILENT", "/SP-", "/NORESTART", "/CLOSEAPPLICATIONS") -PassThru
$process.WaitForExit()
if ($process.ExitCode -ne 0) { throw "Update installer exited with code $($process.ExitCode)" }
Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PSCommandPath -Force
`, psQuote(tempFile), hashCheck)
		return updateScript, scriptContent, nil
	case ".zip":
		updateScript := filepath.Join(scriptDir, "dropo_update.ps1")
		extractDir := filepath.Join(scriptDir, "extract")
		scriptContent := fmt.Sprintf(`$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 2
$package = %s
$dest = %s
$extract = %s
$exe = %s
%s
if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
New-Item -ItemType Directory -Path $extract | Out-Null
Expand-Archive -LiteralPath $package -DestinationPath $extract -Force
Get-ChildItem -LiteralPath $extract | Copy-Item -Destination $dest -Recurse -Force
Remove-Item -LiteralPath $package -Force
Remove-Item -LiteralPath $extract -Recurse -Force
Start-Process -FilePath $exe -WorkingDirectory $dest
Remove-Item -LiteralPath $PSCommandPath -Force
`, psQuote(tempFile), psQuote(execDir), psQuote(extractDir), psQuote(execPath), hashCheck)
		return updateScript, scriptContent, nil
	default:
		_ = os.RemoveAll(scriptDir)
		return "", "", fmt.Errorf("unsupported update asset type: %s", filepath.Ext(tempFile))
	}
}

func psQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

// GetAppVersion возвращает текущую версию приложения
func (a *App) GetAppVersion() map[string]interface{} {
	return GetVersionInfo()
}
