//go:build windows

package main

import (
	"errors"
	"fmt"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	internetOptionPerConnectionOption = 75
	internetPerConnFlags              = 1
	internetPerConnAutoConfigURL      = 4
	internetPerConnFlagsUI            = 10
	proxyTypeDirect                   = 0x00000001
	proxyTypeAutoProxyURL             = 0x00000004
)

var internetQueryOption = windows.NewLazySystemDLL("wininet.dll").NewProc("InternetQueryOptionW")
var globalFree = windows.NewLazySystemDLL("kernel32.dll").NewProc("GlobalFree")

// These layouts mirror INTERNET_PER_CONN_OPTIONW and
// INTERNET_PER_CONN_OPTION_LISTW. uintptr is the largest member of the native
// option union and therefore preserves its alignment on both 32-bit and 64-bit
// Windows.
type internetPerConnectionOption struct {
	option uint32
	value  uintptr
}

type internetPerConnectionOptionList struct {
	size        uint32
	connection  *uint16
	optionCount uint32
	optionError uint32
	options     *internetPerConnectionOption
}

type windowsConnectionProxyState struct {
	Flags         uint32
	AutoConfigURL string
}

func selectivePACConnectionState(pacURL string) windowsConnectionProxyState {
	return windowsConnectionProxyState{
		Flags:         proxyTypeDirect | proxyTypeAutoProxyURL,
		AutoConfigURL: pacURL,
	}
}

// readWindowsConnectionProxyState reads the effective LAN connection profile
// consumed by Chromium and other WinINet-aware applications. Reading only the
// top-level Internet Settings values is insufficient: Windows also maintains a
// per-connection profile which may still say DIRECT.
func readWindowsConnectionProxyState() (windowsConnectionProxyState, error) {
	flags, err := queryWindowsConnectionDWORD(internetPerConnFlagsUI)
	if err != nil {
		// Microsoft documents FLAGS_UI for reads on Windows 7 and later, with the
		// original FLAGS option as the compatibility fallback.
		flags, err = queryWindowsConnectionDWORD(internetPerConnFlags)
		if err != nil {
			return windowsConnectionProxyState{}, err
		}
	}
	autoConfigURL, err := queryWindowsConnectionString(internetPerConnAutoConfigURL)
	if err != nil {
		return windowsConnectionProxyState{}, err
	}
	return windowsConnectionProxyState{Flags: flags, AutoConfigURL: autoConfigURL}, nil
}

func queryWindowsConnectionDWORD(optionID uint32) (uint32, error) {
	option := internetPerConnectionOption{option: optionID}
	if err := queryWindowsConnectionOption(&option); err != nil {
		return 0, err
	}
	return uint32(option.value), nil
}

func queryWindowsConnectionString(optionID uint32) (string, error) {
	option := internetPerConnectionOption{option: optionID}
	if err := queryWindowsConnectionOption(&option); err != nil {
		return "", err
	}
	if option.value == 0 {
		return "", nil
	}
	defer globalFree.Call(option.value)
	return windows.UTF16PtrToString((*uint16)(unsafe.Pointer(option.value))), nil
}

func queryWindowsConnectionOption(option *internetPerConnectionOption) error {
	if option == nil {
		return errors.New("WinINet per-connection option is nil")
	}
	list := internetPerConnectionOptionList{
		size:        uint32(unsafe.Sizeof(internetPerConnectionOptionList{})),
		optionCount: 1,
		options:     option,
	}
	bufferSize := uint32(unsafe.Sizeof(list))
	result, _, callErr := internetQueryOption.Call(
		0,
		internetOptionPerConnectionOption,
		uintptr(unsafe.Pointer(&list)),
		uintptr(unsafe.Pointer(&bufferSize)),
	)
	if result == 0 {
		return winInetProxyCallError("InternetQueryOptionW", callErr)
	}
	return nil
}

// applyWindowsConnectionProxyState updates the effective LAN connection
// profile and verifies the result through WinINet before the caller announces a
// settings change. The verification turns a silent browser bypass into a
// fail-safe startup error.
func applyWindowsConnectionProxyState(state windowsConnectionProxyState) error {
	var urlPointer *uint16
	var err error
	if state.AutoConfigURL != "" {
		urlPointer, err = windows.UTF16PtrFromString(state.AutoConfigURL)
		if err != nil {
			return fmt.Errorf("encode Windows PAC URL: %w", err)
		}
	}
	options := [2]internetPerConnectionOption{
		{option: internetPerConnFlags, value: uintptr(state.Flags)},
		{option: internetPerConnAutoConfigURL, value: uintptr(unsafe.Pointer(urlPointer))},
	}
	list := internetPerConnectionOptionList{
		size:        uint32(unsafe.Sizeof(internetPerConnectionOptionList{})),
		optionCount: uint32(len(options)),
		options:     &options[0],
	}
	result, _, callErr := internetSetOption.Call(
		0,
		internetOptionPerConnectionOption,
		uintptr(unsafe.Pointer(&list)),
		unsafe.Sizeof(list),
	)
	runtime.KeepAlive(urlPointer)
	if result == 0 {
		return winInetProxyCallError("InternetSetOptionW", callErr)
	}
	effective, err := readWindowsConnectionProxyState()
	if err != nil {
		return fmt.Errorf("verify Windows connection proxy state: %w", err)
	}
	if effective.Flags != state.Flags || effective.AutoConfigURL != state.AutoConfigURL {
		return fmt.Errorf(
			"Windows connection proxy state was not applied: flags=0x%x url=%q",
			effective.Flags, effective.AutoConfigURL,
		)
	}
	return nil
}

func winInetProxyCallError(operation string, callErr error) error {
	if callErr == nil || errors.Is(callErr, windows.ERROR_SUCCESS) {
		return errors.New(operation + " failed")
	}
	return fmt.Errorf("%s: %w", operation, callErr)
}
