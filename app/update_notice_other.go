//go:build !windows

package main

func showSystemNotice(string, string) bool { return false }
