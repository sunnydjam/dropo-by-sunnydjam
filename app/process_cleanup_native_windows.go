//go:build windows

package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const internetSettingsRegistryPath = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`

var internetSetOption = windows.NewLazySystemDLL("wininet.dll").NewProc("InternetSetOptionW")
var sendMessageTimeout = windows.NewLazySystemDLL("user32.dll").NewProc("SendMessageTimeoutW")

const (
	hwndBroadcast      = uintptr(0xffff)
	wmSettingChange    = uintptr(0x001a)
	smtoAbortIfHung    = uintptr(0x0002)
	proxyRefreshWaitMS = uintptr(2000)
)

// A port number, an unreachable listener or WPAD alone cannot identify Dropo.
func resetStaleDropoPAC() (bool, string, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, internetSettingsRegistryPath, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return false, "", err
	}
	defer key.Close()
	pac, _, err := key.GetStringValue("AutoConfigURL")
	if errors.Is(err, registry.ErrNotExist) {
		return false, "", nil
	}
	if err != nil {
		return false, "", err
	}
	port := dropoPACPort(pac)
	if port == 0 || loopbackPortListening(port) {
		return false, "", nil
	}
	state, err := readWindowsConnectionProxyState()
	if err != nil {
		return false, pac, err
	}
	if state.AutoConfigURL == pac {
		state.AutoConfigURL = ""
		state.Flags = state.Flags&^proxyTypeAutoProxyURL | proxyTypeDirect
		if err := applyWindowsConnectionProxyState(state); err != nil {
			return false, pac, err
		}
	}
	if readRegistryStringState(key, "AutoConfigURL").value == pac {
		if err := key.DeleteValue("AutoConfigURL"); err != nil {
			return false, pac, err
		}
	}
	notifyWindowsProxySettingsChanged()
	return true, pac, nil
}

func broadcastWindowsProxySettingsChanged() {
	section, err := windows.UTF16PtrFromString(internetSettingsRegistryPath)
	if err != nil {
		return
	}
	var result uintptr
	_, _, _ = sendMessageTimeout.Call(
		hwndBroadcast,
		wmSettingChange,
		0,
		uintptr(unsafe.Pointer(section)),
		smtoAbortIfHung,
		proxyRefreshWaitMS,
		uintptr(unsafe.Pointer(&result)),
	)
}

func loopbackPortListening(port int) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 200*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func killWindowsDropoManagedSidecarsNative(paths []string, roots []string, excludedPID int) ([]int, error) {
	exact := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		if abs, err := filepath.Abs(path); err == nil {
			exact[strings.ToLower(filepath.Clean(abs))] = struct{}{}
		}
	}
	normalizedRoots := make([]string, 0, len(roots))
	for _, root := range roots {
		if abs, err := filepath.Abs(root); err == nil {
			normalizedRoots = append(normalizedRoots, filepath.Join(filepath.Clean(abs), "bin"))
		}
	}

	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer windows.CloseHandle(snapshot)

	ownedNames := map[string]bool{
		"sing-box.exe":    true,
		"ciadpi.exe":      true,
		"winws2.exe":      true,
		"xray.exe":        true,
		"tg-ws-proxy.exe": true,
	}
	entry := windows.ProcessEntry32{}
	entry.Size = uint32(unsafe.Sizeof(entry))
	if err := windows.Process32First(snapshot, &entry); err != nil {
		return nil, err
	}
	var result []int
	var resultErr error
	currentPID := uint32(os.Getpid())
	for {
		if entry.ProcessID != 0 && int(entry.ProcessID) != excludedPID && entry.ProcessID != currentPID && ownedNames[strings.ToLower(windows.UTF16ToString(entry.ExeFile[:]))] {
			process, openErr := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_TERMINATE, false, entry.ProcessID)
			if openErr == nil {
				imagePath, pathErr := processImagePath(process)
				owned := pathErr == nil && processPathOwned(imagePath, exact, normalizedRoots)
				if owned {
					if terminateErr := windows.TerminateProcess(process, 1); terminateErr != nil {
						resultErr = errors.Join(resultErr, fmt.Errorf("terminate pid %d: %w", entry.ProcessID, terminateErr))
					} else {
						waitStatus, waitErr := windows.WaitForSingleObject(process, uint32(2*time.Second/time.Millisecond))
						if waitErr != nil {
							resultErr = errors.Join(resultErr, fmt.Errorf("wait for pid %d: %w", entry.ProcessID, waitErr))
						} else if waitStatus != windows.WAIT_OBJECT_0 {
							resultErr = errors.Join(resultErr, fmt.Errorf("wait for pid %d timed out", entry.ProcessID))
						} else {
							result = append(result, int(entry.ProcessID))
						}
					}
				}
				_ = windows.CloseHandle(process)
			}
		}
		if err := windows.Process32Next(snapshot, &entry); err != nil {
			if errors.Is(err, windows.ERROR_NO_MORE_FILES) {
				break
			}
			return result, errors.Join(resultErr, err)
		}
	}
	return result, resultErr
}

func processImagePath(process windows.Handle) (string, error) {
	buffer := make([]uint16, 32768)
	size := uint32(len(buffer))
	if err := windows.QueryFullProcessImageName(process, 0, &buffer[0], &size); err != nil {
		return "", err
	}
	return filepath.Clean(windows.UTF16ToString(buffer[:size])), nil
}

func processPathOwned(imagePath string, exact map[string]struct{}, roots []string) bool {
	abs, err := filepath.Abs(imagePath)
	if err != nil {
		return false
	}
	abs = filepath.Clean(abs)
	if _, ok := exact[strings.ToLower(abs)]; ok {
		return true
	}
	for _, root := range roots {
		if pathIsInside(abs, root) {
			return true
		}
	}
	return false
}
