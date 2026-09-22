//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

func TestWFPGuardRuntimeMigrationLockSerializesThreads(t *testing.T) {
	name := fmt.Sprintf(`Global\DropoWFPRuntimeMigrationTest_%d_%d`, os.Getpid(), time.Now().UnixNano())
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &token); err != nil {
		t.Fatal(err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	// Pre-create the object without an Administrators ACE. This exercises
	// opening an existing mutex through the target user's *minimal* rights,
	// even when the test account also belongs to Administrators.
	descriptor, err := windows.SecurityDescriptorFromString(
		"D:P(A;;GA;;;SY)(A;;0x00100001;;;" + user.User.Sid.String() + ")",
	)
	if err != nil {
		t.Fatal(err)
	}
	namePtr, err := windows.UTF16PtrFromString(name)
	if err != nil {
		t.Fatal(err)
	}
	security := windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: descriptor,
	}
	precreated, err := windows.CreateMutexEx(&security, namePtr, 0, windows.SYNCHRONIZE|windows.MUTEX_MODIFY_STATE)
	runtime.KeepAlive(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(precreated)

	release, err := acquireWFPGuardRuntimeMigrationLockNamed(name, 0)
	if err != nil {
		t.Fatalf("acquire migration lock: %v", err)
	}
	defer func() {
		if release != nil {
			release()
		}
	}()

	blocked := make(chan error, 1)
	go func() {
		otherRelease, otherErr := acquireWFPGuardRuntimeMigrationLockNamed(name, 0)
		if otherErr == nil {
			otherRelease()
		}
		blocked <- otherErr
	}()
	if err := <-blocked; err == nil {
		t.Fatal("a second thread acquired the held migration lock")
	}

	release()
	release = nil
	again, err := acquireWFPGuardRuntimeMigrationLockNamed(name, 0)
	if err != nil {
		t.Fatalf("reacquire released migration lock: %v", err)
	}
	again()
}

func TestWFPGuardVersionFromServiceCommandLine(t *testing.T) {
	root := filepath.Join(t.TempDir(), "protected runtime")
	path := filepath.Join(root, "previous-version", "bin", wfpGuardBinaryName)
	version, err := wfpGuardVersionFromCommandLine(`"`+path+`" --service`, root)
	if err != nil || version != "previous-version" {
		t.Fatalf("guard version = %q, err = %v", version, err)
	}
}

func TestWFPGuardVersionRejectsUntrustedServicePaths(t *testing.T) {
	root := filepath.Join(t.TempDir(), "runtime")
	tests := []struct {
		name string
		path string
	}{
		{"outside runtime", filepath.Join(t.TempDir(), "old", "bin", wfpGuardBinaryName)},
		{"wrong binary", filepath.Join(root, "old", "bin", "dropo-core.exe")},
		{"unversioned", filepath.Join(root, "bin", wfpGuardBinaryName)},
		{"relative", filepath.Join("old", "bin", wfpGuardBinaryName)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := wfpGuardVersionFromCommandLine(`"`+tt.path+`"`, root); err == nil {
				t.Fatalf("untrusted guard path %q accepted", tt.path)
			}
		})
	}
}
