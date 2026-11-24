package main

import (
	"context"
	"errors"
	"golang.org/x/sys/windows"
	"math/bits"
	"net"
	"syscall"
	"time"
)

func dialResidentialPhysical(ctx context.Context, network, address string) (net.Conn, error) {
	_, index := residentialPhysicalNetwork()
	if index == 0 {
		return nil, errors.New("physical IPv4 interface unavailable")
	}
	d := net.Dialer{Timeout: 5 * time.Second, Control: func(_, _ string, conn syscall.RawConn) error {
		var optionErr error
		err := conn.Control(func(fd uintptr) {
			optionErr = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, 31, int(bits.ReverseBytes32(index)))
		})
		if err != nil {
			return err
		}
		return optionErr
	}}
	return d.DialContext(ctx, network, address)
}
