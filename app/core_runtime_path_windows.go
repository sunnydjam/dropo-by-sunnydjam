//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	wfpGuardServiceName      = "DropoWFPGuard"
	wfpGuardBinaryName       = "dropo-wfp-guard.exe"
	wfpGuardRuntimeMutexName = `Global\DropoWFPRuntimeMigration`
)

func prepareProtectedRuntime(version string) (string, error) {
	programData, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, windows.KF_FLAG_DEFAULT)
	if err != nil || strings.TrimSpace(programData) == "" {
		return "", fmt.Errorf("resolve ProgramData known folder: %w", err)
	}
	root := filepath.Join(filepath.Clean(programData), AppDataDirName)
	if err := createAndProtectDirectory(root); err != nil {
		return "", err
	}
	runtimeRoot := filepath.Join(root, "runtime")
	if err := createAndProtectDirectory(runtimeRoot); err != nil {
		return "", err
	}
	path := filepath.Join(runtimeRoot, filepath.Base(version))
	if filepath.Base(version) != version || version == "." || version == ".." {
		return "", fmt.Errorf("invalid protected runtime version")
	}
	if err := createAndProtectDirectory(path); err != nil {
		return "", err
	}
	return path, nil
}

// cleanupStaleProtectedRuntimes removes only versioned dependency caches owned
// by dropo. The current runtime, the protected updater workspace and the
// runtime referenced by a future persistent WFP guard service are kept.
// Startup process cleanup runs before this function, but it must never remove
// a guard binary: unlike managed child processes, that service outlives the UI.
func cleanupStaleProtectedRuntimes(currentVersion string) (int, error) {
	releaseMigrationLock, err := acquireWFPGuardRuntimeMigrationLock()
	if err != nil {
		// An updater may be changing the service ImagePath. Retaining stale
		// runtime directories is safer than deleting a guard executable.
		return 0, fmt.Errorf("preserve protected runtimes until WFP guard migration lock is available: %w", err)
	}
	defer releaseMigrationLock()

	programData, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, windows.KF_FLAG_DEFAULT)
	if err != nil || strings.TrimSpace(programData) == "" {
		return 0, fmt.Errorf("resolve ProgramData known folder: %w", err)
	}
	runtimeRoot := filepath.Join(filepath.Clean(programData), AppDataDirName, "runtime")
	guardVersion, err := wfpGuardRuntimeVersion(runtimeRoot)
	if err != nil {
		// If SCM readback is unavailable or inconsistent, keep the old runtimes.
		// Deleting a service's ImagePath is worse than retaining a cache directory.
		return 0, fmt.Errorf("preserve protected runtimes until WFP guard path is verified: %w", err)
	}
	entries, err := os.ReadDir(runtimeRoot)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	removed := 0
	for _, entry := range entries {
		if !entry.IsDir() || entry.Name() == filepath.Base(currentVersion) || entry.Name() == "updates" || strings.EqualFold(entry.Name(), guardVersion) {
			continue
		}
		target := filepath.Join(runtimeRoot, entry.Name())
		rel, relErr := filepath.Rel(runtimeRoot, target)
		if relErr != nil || rel == "." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
			return removed, fmt.Errorf("refuse stale runtime path %q", target)
		}
		if err := rejectWindowsReparsePoint(target); err != nil {
			return removed, fmt.Errorf("refuse stale runtime reparse point or non-directory %q: %w", target, err)
		}
		if err := os.RemoveAll(target); err != nil {
			return removed, fmt.Errorf("remove stale runtime %s: %w", entry.Name(), err)
		}
		removed++
	}
	return removed, nil
}

// Keep mutex acquisition, SCM readback and deletion on one OS thread. Windows
// mutex ownership is thread-affine, unlike Go goroutine scheduling. A future
// installer must hold this same named mutex across ImagePath migration and
// runtime retirement; until then, this only protects cleanup against another
// cooperating Dropo process, not an installer that ignores the protocol.
func acquireWFPGuardRuntimeMigrationLock() (func(), error) {
	return acquireWFPGuardRuntimeMigrationLockNamed(wfpGuardRuntimeMutexName, 5*time.Second)
}

func acquireWFPGuardRuntimeMigrationLockNamed(mutexName string, timeout time.Duration) (func(), error) {
	if timeout < 0 || timeout > 5*time.Second {
		return nil, fmt.Errorf("invalid WFP guard runtime migration lock timeout")
	}
	runtime.LockOSThread()
	name, err := windows.UTF16PtrFromString(mutexName)
	if err != nil {
		runtime.UnlockOSThread()
		return nil, err
	}
	security, descriptor, err := wfpGuardRuntimeMutexSecurity()
	if err != nil {
		runtime.UnlockOSThread()
		return nil, err
	}
	// CreateMutex requests MUTEX_ALL_ACCESS when the name already exists, which
	// exceeds the narrowly granted user ACE. CreateMutexEx requests only the
	// two rights needed to wait and release, including for an existing mutex.
	handle, err := windows.CreateMutexEx(&security, name, 0, windows.SYNCHRONIZE|windows.MUTEX_MODIFY_STATE)
	runtime.KeepAlive(descriptor)
	if err != nil && !errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		runtime.UnlockOSThread()
		return nil, fmt.Errorf("create WFP guard runtime migration mutex: %w", err)
	}
	if handle == 0 {
		runtime.UnlockOSThread()
		return nil, fmt.Errorf("create WFP guard runtime migration mutex returned a null handle")
	}
	status, err := windows.WaitForSingleObject(handle, uint32(timeout/time.Millisecond))
	if err != nil || (status != windows.WAIT_OBJECT_0 && status != windows.WAIT_ABANDONED) {
		_ = windows.CloseHandle(handle)
		runtime.UnlockOSThread()
		if err != nil {
			return nil, fmt.Errorf("wait for WFP guard runtime migration mutex: %w", err)
		}
		return nil, fmt.Errorf("WFP guard runtime migration mutex wait ended with status %d", status)
	}
	return func() {
		_ = windows.ReleaseMutex(handle)
		_ = windows.CloseHandle(handle)
		runtime.UnlockOSThread()
	}, nil
}

// The user core and an elevated installer must be able to synchronize even
// when either creates the mutex first. No other interactive user is granted
// access. This does not protect against an administrator or a prior malicious
// namespace squatter; failure to open the mutex simply preserves old files.
func wfpGuardRuntimeMutexSecurity() (windows.SecurityAttributes, *windows.SECURITY_DESCRIPTOR, error) {
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &token); err != nil {
		return windows.SecurityAttributes{}, nil, fmt.Errorf("query WFP guard runtime lock user: %w", err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil || user == nil || user.User.Sid == nil {
		return windows.SecurityAttributes{}, nil, fmt.Errorf("query WFP guard runtime lock SID: %w", err)
	}
	// SYNCHRONIZE | MUTEX_MODIFY_STATE for the target user; SYSTEM and
	// Administrators can create, wait, and release during installer migration.
	sddl := "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x00100001;;;" + user.User.Sid.String() + ")"
	descriptor, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return windows.SecurityAttributes{}, nil, fmt.Errorf("build WFP guard runtime lock DACL: %w", err)
	}
	return windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: descriptor,
	}, descriptor, nil
}

func wfpGuardRuntimeVersion(runtimeRoot string) (string, error) {
	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return "", fmt.Errorf("connect to service manager: %w", err)
	}
	defer windows.CloseServiceHandle(manager)
	serviceName, err := windows.UTF16PtrFromString(wfpGuardServiceName)
	if err != nil {
		return "", fmt.Errorf("encode WFP guard service name: %w", err)
	}
	serviceHandle, err := windows.OpenService(manager, serviceName, windows.SERVICE_QUERY_CONFIG)
	if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("query WFP guard service: %w", err)
	}
	service := mgr.Service{Name: wfpGuardServiceName, Handle: serviceHandle}
	defer service.Close()
	config, err := service.Config()
	if err != nil {
		return "", fmt.Errorf("read WFP guard service config: %w", err)
	}
	return wfpGuardVersionFromCommandLine(config.BinaryPathName, runtimeRoot)
}

func wfpGuardVersionFromCommandLine(commandLine, runtimeRoot string) (string, error) {
	argv, err := windows.DecomposeCommandLine(commandLine)
	if err != nil || len(argv) == 0 || !filepath.IsAbs(argv[0]) {
		return "", fmt.Errorf("WFP guard service ImagePath is not an absolute command")
	}
	rel, err := filepath.Rel(filepath.Clean(runtimeRoot), filepath.Clean(argv[0]))
	if err != nil {
		return "", fmt.Errorf("resolve WFP guard service ImagePath: %w", err)
	}
	parts := strings.Split(filepath.ToSlash(rel), "/")
	if len(parts) != 3 || parts[0] == "" || parts[0] == "." || parts[0] == ".." ||
		!strings.EqualFold(parts[1], "bin") || !strings.EqualFold(parts[2], wfpGuardBinaryName) {
		return "", fmt.Errorf("WFP guard service ImagePath is outside the protected versioned runtime")
	}
	return parts[0], nil
}

func createAndProtectDirectory(path string) error {
	if err := rejectWindowsReparsePoint(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.Mkdir(path, 0755); err != nil && !os.IsExist(err) {
		return fmt.Errorf("create protected directory %s: %w", path, err)
	}
	if err := rejectWindowsReparsePoint(path); err != nil {
		return err
	}
	systemSID, err := windows.StringToSid("S-1-5-18")
	if err != nil {
		return err
	}
	adminSID, err := windows.StringToSid("S-1-5-32-544")
	if err != nil {
		return err
	}
	entries := []windows.EXPLICIT_ACCESS{
		{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.GRANT_ACCESS,
			Inheritance:       windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
			Trustee: windows.TRUSTEE{
				TrusteeForm: windows.TRUSTEE_IS_SID, TrusteeType: windows.TRUSTEE_IS_USER,
				TrusteeValue: windows.TrusteeValueFromSID(systemSID),
			},
		},
		{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.GRANT_ACCESS,
			Inheritance:       windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
			Trustee: windows.TRUSTEE{
				TrusteeForm: windows.TRUSTEE_IS_SID, TrusteeType: windows.TRUSTEE_IS_GROUP,
				TrusteeValue: windows.TrusteeValueFromSID(adminSID),
			},
		},
	}
	acl, err := windows.ACLFromEntries(entries, nil)
	if err != nil {
		return fmt.Errorf("build protected runtime ACL: %w", err)
	}
	if err := windows.SetNamedSecurityInfo(
		path,
		windows.SE_FILE_OBJECT,
		windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		adminSID,
		nil,
		acl,
		nil,
	); err != nil {
		return fmt.Errorf("protect runtime ACL: %w", err)
	}
	return rejectWindowsReparsePoint(path)
}

func rejectWindowsReparsePoint(path string) error {
	ptr, err := syscall.UTF16PtrFromString(filepath.Clean(path))
	if err != nil {
		return err
	}
	attrs, err := windows.GetFileAttributes(ptr)
	if err != nil {
		return err
	}
	if attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return fmt.Errorf("protected runtime path is a reparse point: %s", path)
	}
	if attrs&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return fmt.Errorf("protected runtime path is not a directory: %s", path)
	}
	return nil
}
