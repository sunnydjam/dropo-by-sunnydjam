//go:build windows

package main

import (
	"fmt"
	"os"

	"dropo/wfpguardservice"
)

// The signed installer must pin the target user SID in the SCM ImagePath.
// This binary never installs itself or runs outside the Service Control Manager.
func main() {
	if len(os.Args) != 4 || os.Args[1] != "--service" || os.Args[2] != "--user-sid" {
		fmt.Fprintln(os.Stderr, "guard requires --service --user-sid <SID> from SCM")
		os.Exit(2)
	}
	if err := wfpguardservice.RunWindowsService(os.Args[3]); err != nil {
		fmt.Fprintln(os.Stderr, "guard service failed:", err)
		os.Exit(1)
	}
}
