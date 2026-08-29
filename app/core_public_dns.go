package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

var publicDNSQueryID atomic.Uint32

// lookupPublicHostWithoutHosts asks the active adapter DNS servers directly.
// It deliberately bypasses the Windows hosts overlay so a native application's
// exact fake bootstrap name can still be connected to its real public address
// by Dropo's in-process relay.
func lookupPublicHostWithoutHosts(ctx context.Context, host string) ([]netip.Addr, error) {
	host = normalizeProxyHost(host)
	if host == "" || net.ParseIP(host) != nil {
		return nil, errors.New("public DNS host is invalid")
	}
	servers := systemDNSServers()
	if len(servers) == 0 {
		if allowDefaultDNSFallback() {
			addresses, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
			if err != nil {
				return nil, err
			}
			return uniquePublicAddresses(addresses), nil
		}
		return nil, errors.New("no active system DNS server is available")
	}
	var lastErr error
	for _, server := range servers {
		addresses := make([]netip.Addr, 0, 4)
		for _, queryType := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
			resolved, err := queryPublicDNS(ctx, server, host, queryType)
			if err != nil {
				lastErr = err
				continue
			}
			addresses = append(addresses, resolved...)
		}
		addresses = uniquePublicAddresses(addresses)
		if len(addresses) > 0 {
			return addresses, nil
		}
	}
	if lastErr == nil {
		lastErr = errors.New("DNS response contained no public address")
	}
	return nil, lastErr
}

func queryPublicDNS(ctx context.Context, server netip.Addr, host string, queryType dnsmessage.Type) ([]netip.Addr, error) {
	name, err := dnsmessage.NewName(strings.TrimSuffix(host, ".") + ".")
	if err != nil {
		return nil, err
	}
	id := uint16(publicDNSQueryID.Add(1))
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, RecursionDesired: true})
	builder.EnableCompression()
	if err := builder.StartQuestions(); err != nil {
		return nil, err
	}
	if err := builder.Question(dnsmessage.Question{Name: name, Type: queryType, Class: dnsmessage.ClassINET}); err != nil {
		return nil, err
	}
	query, err := builder.Finish()
	if err != nil {
		return nil, err
	}

	dialer := net.Dialer{Timeout: 2 * time.Second}
	connection, err := dialer.DialContext(ctx, "udp", net.JoinHostPort(server.String(), "53"))
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	deadline := time.Now().Add(3 * time.Second)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	_ = connection.SetDeadline(deadline)
	if _, err := connection.Write(query); err != nil {
		return nil, err
	}
	response := make([]byte, 4096)
	count, err := connection.Read(response)
	if err != nil {
		return nil, err
	}
	return parsePublicDNSAnswer(response[:count], id)
}

func parsePublicDNSAnswer(message []byte, id uint16) ([]netip.Addr, error) {
	var parser dnsmessage.Parser
	header, err := parser.Start(message)
	if err != nil {
		return nil, err
	}
	if header.ID != id || !header.Response || header.Truncated || header.RCode != dnsmessage.RCodeSuccess {
		return nil, fmt.Errorf("unusable DNS response id=%d truncated=%t rcode=%s", header.ID, header.Truncated, header.RCode)
	}
	if err := parser.SkipAllQuestions(); err != nil {
		return nil, err
	}
	addresses := make([]netip.Addr, 0, 4)
	for {
		answer, err := parser.AnswerHeader()
		if errors.Is(err, dnsmessage.ErrSectionDone) {
			break
		}
		if err != nil {
			return nil, err
		}
		switch answer.Type {
		case dnsmessage.TypeA:
			resource, err := parser.AResource()
			if err != nil {
				return nil, err
			}
			addresses = append(addresses, netip.AddrFrom4(resource.A))
		case dnsmessage.TypeAAAA:
			resource, err := parser.AAAAResource()
			if err != nil {
				return nil, err
			}
			addresses = append(addresses, netip.AddrFrom16(resource.AAAA))
		default:
			if err := parser.SkipAnswer(); err != nil {
				return nil, err
			}
		}
	}
	return uniquePublicAddresses(addresses), nil
}

func uniquePublicAddresses(addresses []netip.Addr) []netip.Addr {
	result := make([]netip.Addr, 0, len(addresses))
	seen := make(map[netip.Addr]struct{}, len(addresses))
	for _, address := range addresses {
		address = address.Unmap()
		if !zapretPublicAddress(address) || dropoFakeIPv4Prefix.Contains(address) {
			continue
		}
		if _, exists := seen[address]; exists {
			continue
		}
		seen[address] = struct{}{}
		result = append(result, address)
	}
	return result
}
