//go:build windows

// Package wfpguard contains the bounded policy validation and native WFP
// readback primitives for the future, separately installed Windows guard.
// This file intentionally has no WFP object creation or deletion functions.
package wfpguard

import (
	"errors"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	rpcCAuthnWinnt       = 10
	fwpmTxnReadOnly      = 1
	maxReadbackFilters   = 64
	maxProviderDataBytes = 4096
)

var (
	fwpuclnt              = windows.NewLazySystemDLL("fwpuclnt.dll")
	fwpmEngineOpen        = fwpuclnt.NewProc("FwpmEngineOpen0")
	fwpmEngineClose       = fwpuclnt.NewProc("FwpmEngineClose0")
	fwpmTransactionBegin  = fwpuclnt.NewProc("FwpmTransactionBegin0")
	fwpmTransactionCommit = fwpuclnt.NewProc("FwpmTransactionCommit0")
	fwpmTransactionAbort  = fwpuclnt.NewProc("FwpmTransactionAbort0")
	fwpmProviderGetByKey  = fwpuclnt.NewProc("FwpmProviderGetByKey0")
	fwpmSubLayerGetByKey  = fwpuclnt.NewProc("FwpmSubLayerGetByKey0")
	fwpmFilterGetByKey    = fwpuclnt.NewProc("FwpmFilterGetByKey0")
	fwpmFreeMemory        = fwpuclnt.NewProc("FwpmFreeMemory0")
)

// ReadbackKeys identifies one owned provider, one owned sublayer and a bounded
// set of filters. Identifiers must be supplied by a trusted guard, not IPC.
type ReadbackKeys struct {
	Provider windows.GUID
	SubLayer windows.GUID
	Filters  []windows.GUID
}

// Readback is a point-in-time copy of WFP objects. It is diagnostic data, not
// evidence that physical traffic is blocked: conditions, competing filters,
// endpoint exceptions and service lifetime are not verified here.
type Readback struct {
	Provider ProviderInfo
	SubLayer SubLayerInfo
	Filters  []FilterInfo
}

type ProviderInfo struct {
	Key   windows.GUID
	Flags uint32
	Data  []byte
}

type SubLayerInfo struct {
	Key         windows.GUID
	ProviderKey windows.GUID
	Flags       uint32
	Weight      uint16
	Data        []byte
}

type FilterInfo struct {
	Key            windows.GUID
	ProviderKey    windows.GUID
	LayerKey       windows.GUID
	SubLayerKey    windows.GUID
	Flags          uint32
	ConditionCount uint32
	ActionType     uint32
	Data           []byte
}

// Inspect opens a local, non-dynamic WFP session and reads all requested
// objects inside one read-only transaction. It never installs or removes a
// filter. Missing objects, mismatched ownership and malformed native results
// fail closed with an error; no partial snapshot is returned.
func Inspect(keys ReadbackKeys) (Readback, error) {
	if err := validateReadbackKeys(keys); err != nil {
		return Readback{}, err
	}

	var engine windows.Handle
	status, _, _ := fwpmEngineOpen.Call(0, rpcCAuthnWinnt, 0, 0, uintptr(unsafe.Pointer(&engine)))
	runtime.KeepAlive(&engine)
	if err := wfpStatus("FwpmEngineOpen0", status); err != nil {
		return Readback{}, err
	}
	if engine == 0 {
		return Readback{}, errors.New("FwpmEngineOpen0 returned a null engine")
	}
	defer fwpmEngineClose.Call(uintptr(engine))

	if err := wfpStatus("FwpmTransactionBegin0", callWFP(fwpmTransactionBegin, uintptr(engine), fwpmTxnReadOnly)); err != nil {
		return Readback{}, err
	}
	committed := false
	defer func() {
		if !committed {
			fwpmTransactionAbort.Call(uintptr(engine))
		}
	}()

	provider, err := readProvider(engine, keys.Provider)
	if err != nil {
		return Readback{}, err
	}
	sublayer, err := readSubLayer(engine, keys.SubLayer)
	if err != nil {
		return Readback{}, err
	}
	if sublayer.ProviderKey != keys.Provider {
		return Readback{}, errors.New("WFP sublayer is not owned by requested provider")
	}

	result := Readback{Provider: provider, SubLayer: sublayer, Filters: make([]FilterInfo, 0, len(keys.Filters))}
	for _, key := range keys.Filters {
		filter, readErr := readFilter(engine, key)
		if readErr != nil {
			return Readback{}, readErr
		}
		if filter.ProviderKey != keys.Provider || filter.SubLayerKey != keys.SubLayer {
			return Readback{}, fmt.Errorf("WFP filter %v has unexpected owner or sublayer", key)
		}
		result.Filters = append(result.Filters, filter)
	}
	if err := wfpStatus("FwpmTransactionCommit0", callWFP(fwpmTransactionCommit, uintptr(engine))); err != nil {
		return Readback{}, err
	}
	committed = true
	return result, nil
}

func validateReadbackKeys(keys ReadbackKeys) error {
	if keys.Provider == (windows.GUID{}) || keys.SubLayer == (windows.GUID{}) {
		return errors.New("WFP provider and sublayer keys must be nonzero")
	}
	if len(keys.Filters) == 0 || len(keys.Filters) > maxReadbackFilters {
		return fmt.Errorf("WFP readback requires 1..%d filter keys", maxReadbackFilters)
	}
	seen := make(map[windows.GUID]struct{}, len(keys.Filters))
	for _, key := range keys.Filters {
		if key == (windows.GUID{}) {
			return errors.New("WFP filter key must be nonzero")
		}
		if _, exists := seen[key]; exists {
			return errors.New("duplicate WFP filter key")
		}
		seen[key] = struct{}{}
	}
	return nil
}

func readProvider(engine windows.Handle, key windows.GUID) (ProviderInfo, error) {
	var native *fwpmProvider0
	if err := getByKey(fwpmProviderGetByKey, "FwpmProviderGetByKey0", engine, &key, unsafe.Pointer(&native)); err != nil {
		return ProviderInfo{}, err
	}
	if native == nil {
		return ProviderInfo{}, errors.New("FwpmProviderGetByKey0 returned a null provider")
	}
	defer freeWFP(unsafe.Pointer(native))
	if native.Key != key {
		return ProviderInfo{}, errors.New("WFP provider key changed during readback")
	}
	data, err := copyProviderData(native.ProviderData)
	if err != nil {
		return ProviderInfo{}, err
	}
	return ProviderInfo{Key: native.Key, Flags: native.Flags, Data: data}, nil
}

func readSubLayer(engine windows.Handle, key windows.GUID) (SubLayerInfo, error) {
	var native *fwpmSubLayer0
	if err := getByKey(fwpmSubLayerGetByKey, "FwpmSubLayerGetByKey0", engine, &key, unsafe.Pointer(&native)); err != nil {
		return SubLayerInfo{}, err
	}
	if native == nil {
		return SubLayerInfo{}, errors.New("FwpmSubLayerGetByKey0 returned a null sublayer")
	}
	defer freeWFP(unsafe.Pointer(native))
	if native.Key != key || native.ProviderKey == nil {
		return SubLayerInfo{}, errors.New("WFP sublayer key or provider is invalid")
	}
	data, err := copyProviderData(native.ProviderData)
	if err != nil {
		return SubLayerInfo{}, err
	}
	return SubLayerInfo{Key: native.Key, ProviderKey: *native.ProviderKey, Flags: native.Flags, Weight: native.Weight, Data: data}, nil
}

func readFilter(engine windows.Handle, key windows.GUID) (FilterInfo, error) {
	var native *fwpmFilter0Prefix
	if err := getByKey(fwpmFilterGetByKey, "FwpmFilterGetByKey0", engine, &key, unsafe.Pointer(&native)); err != nil {
		return FilterInfo{}, err
	}
	if native == nil {
		return FilterInfo{}, errors.New("FwpmFilterGetByKey0 returned a null filter")
	}
	defer freeWFP(unsafe.Pointer(native))
	if native.Key != key || native.ProviderKey == nil {
		return FilterInfo{}, errors.New("WFP filter key or provider is invalid")
	}
	if native.NumFilterConditions > maxReadbackFilters {
		return FilterInfo{}, errors.New("WFP filter has too many conditions for bounded readback")
	}
	data, err := copyProviderData(native.ProviderData)
	if err != nil {
		return FilterInfo{}, err
	}
	return FilterInfo{
		Key: native.Key, ProviderKey: *native.ProviderKey, LayerKey: native.LayerKey,
		SubLayerKey: native.SubLayerKey, Flags: native.Flags,
		ConditionCount: native.NumFilterConditions, ActionType: native.Action.Type,
		Data: data,
	}, nil
}

func copyProviderData(blob fwpByteBlob) ([]byte, error) {
	if blob.Size > maxProviderDataBytes {
		return nil, fmt.Errorf("WFP provider data exceeds %d bytes", maxProviderDataBytes)
	}
	if blob.Size == 0 {
		return nil, nil
	}
	if blob.Data == nil {
		return nil, errors.New("WFP provider data has null pointer")
	}
	return append([]byte(nil), unsafe.Slice(blob.Data, blob.Size)...), nil
}

func callWFP(proc *windows.LazyProc, args ...uintptr) uintptr {
	status, _, _ := proc.Call(args...)
	return status
}

// Keep Go pointers typed until the direct syscall boundary. Passing their
// uintptr representations through a variadic helper could allow a stack move
// or GC before the native call uses them.
func getByKey(proc *windows.LazyProc, operation string, engine windows.Handle, key *windows.GUID, result unsafe.Pointer) error {
	status, _, _ := proc.Call(uintptr(engine), uintptr(unsafe.Pointer(key)), uintptr(result))
	runtime.KeepAlive(key)
	runtime.KeepAlive(result)
	return wfpStatus(operation, status)
}

func wfpStatus(operation string, status uintptr) error {
	if status == 0 {
		return nil
	}
	return fmt.Errorf("%s: %w", operation, syscall.Errno(status))
}

func freeWFP(pointer unsafe.Pointer) {
	ptr := pointer
	fwpmFreeMemory.Call(uintptr(unsafe.Pointer(&ptr)))
	runtime.KeepAlive(pointer)
}

// The following layouts mirror only the required prefix of the Microsoft
// FWPM_*0 structures. The ABI offsets are pinned in wfp_windows_test.go.
type fwpmDisplayData0 struct {
	Name        *uint16
	Description *uint16
}

type fwpByteBlob struct {
	Size uint32
	Data *byte
}

type fwpmProvider0 struct {
	Key          windows.GUID
	Display      fwpmDisplayData0
	Flags        uint32
	ProviderData fwpByteBlob
	ServiceName  *uint16
}

type fwpmSubLayer0 struct {
	Key          windows.GUID
	Display      fwpmDisplayData0
	Flags        uint32
	ProviderKey  *windows.GUID
	ProviderData fwpByteBlob
	Weight       uint16
}

type fwpValue0 struct {
	Type  uint32
	Value uintptr
}

type fwpmAction0 struct {
	Type uint32
	Key  windows.GUID
}

type fwpmFilter0Prefix struct {
	Key                 windows.GUID
	Display             fwpmDisplayData0
	Flags               uint32
	ProviderKey         *windows.GUID
	ProviderData        fwpByteBlob
	LayerKey            windows.GUID
	SubLayerKey         windows.GUID
	Weight              fwpValue0
	NumFilterConditions uint32
	FilterConditions    uintptr
	Action              fwpmAction0
}
