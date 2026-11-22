//go:build windows

package main

import (
	"testing"
	"unsafe"
)

func TestWinINetStringOptionMatchesNativeUnionLayout(t *testing.T) {
	integerLayout := unsafe.Sizeof(internetPerConnectionOption{})
	pointerLayout := unsafe.Sizeof(internetPerConnectionStringOption{})
	if pointerLayout != integerLayout {
		t.Fatalf(
			"WinINet option layouts differ: integer=%d pointer=%d",
			integerLayout,
			pointerLayout,
		)
	}
}
