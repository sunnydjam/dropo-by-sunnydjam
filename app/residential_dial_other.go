//go:build !windows

package main

import (
	"context"
	"errors"
	"net"
)

func dialResidentialPhysical(context.Context, string, string) (net.Conn, error) {
	return nil, errors.New("physical interface binding unavailable on this platform")
}
