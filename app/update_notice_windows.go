//go:build windows

package main

import (
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

type updateNotifyIcon struct {
	size                uint32
	window              windows.Handle
	id, flags, callback uint32
	icon                windows.Handle
	tip                 [128]uint16
	state, stateMask    uint32
	info                [256]uint16
	timeoutOrVersion    uint32
	title               [64]uint16
	infoFlags           uint32
	guid                windows.GUID
	balloonIcon         windows.Handle
}

func showSystemNotice(titleText, messageText string) bool {
	if !isSystrayReady() {
		return false
	}
	user32 := windows.NewLazySystemDLL("user32.dll")
	find := user32.NewProc("FindWindowExW")
	pidOf := user32.NewProc("GetWindowThreadProcessId")
	class, _ := windows.UTF16PtrFromString("SystrayClass")
	title, err := windows.UTF16FromString(titleText)
	if err != nil {
		return false
	}
	message, err := windows.UTF16FromString(messageText)
	if err != nil {
		return false
	}
	var window uintptr
	for {
		window, _, _ = find.Call(0, window, uintptr(unsafe.Pointer(class)), 0)
		if window == 0 {
			return false
		}
		var pid uint32
		pidOf.Call(window, uintptr(unsafe.Pointer(&pid)))
		if pid == uint32(os.Getpid()) {
			break
		}
	}
	// The pinned systray runtime registers icon ID 100 for this window.
	notice := updateNotifyIcon{window: windows.Handle(window), id: 100, flags: 0x10, infoFlags: 1}
	notice.size = uint32(unsafe.Sizeof(notice))
	copy(notice.title[:len(notice.title)-1], title)
	copy(notice.info[:len(notice.info)-1], message)
	shell := windows.NewLazySystemDLL("shell32.dll").NewProc("Shell_NotifyIconW")
	ok, _, _ := shell.Call(1, uintptr(unsafe.Pointer(&notice)))
	return ok != 0
}
