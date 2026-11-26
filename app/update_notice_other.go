//go:build !windows

package main

func showUpdateSystemNotice(string) bool { return false }
