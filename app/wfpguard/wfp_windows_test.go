//go:build windows

package wfpguard

import (
	"errors"
	"os"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func testGUID(n uint32) windows.GUID { return windows.GUID{Data1: n} }

func TestReadbackKeysRejectsMalformedAndUnboundedRequests(t *testing.T) {
	valid := ReadbackKeys{Provider: testGUID(1), SubLayer: testGUID(2), Filters: []windows.GUID{testGUID(3)}}
	if err := validateReadbackKeys(valid); err != nil {
		t.Fatalf("valid keys: %v", err)
	}
	cases := []ReadbackKeys{
		{},
		{Provider: testGUID(1), SubLayer: testGUID(2)},
		{Provider: testGUID(1), SubLayer: testGUID(2), Filters: []windows.GUID{{}}},
		{Provider: testGUID(1), SubLayer: testGUID(2), Filters: []windows.GUID{testGUID(3), testGUID(3)}},
		{Provider: testGUID(1), SubLayer: testGUID(2), Filters: make([]windows.GUID, maxReadbackFilters+1)},
	}
	for i, keys := range cases {
		if err := validateReadbackKeys(keys); err == nil {
			t.Errorf("case %d accepted invalid keys", i)
		}
		if _, err := Inspect(keys); err == nil {
			t.Errorf("case %d reached native readback", i)
		}
	}
}

func TestCopyProviderDataIsBoundedAndDetached(t *testing.T) {
	if _, err := copyProviderData(fwpByteBlob{Size: maxProviderDataBytes + 1}); err == nil {
		t.Fatal("accepted oversized native blob")
	}
	if _, err := copyProviderData(fwpByteBlob{Size: 1}); err == nil {
		t.Fatal("accepted null native pointer")
	}
	input := []byte{1, 2, 3}
	got, err := copyProviderData(fwpByteBlob{Size: uint32(len(input)), Data: &input[0]})
	if err != nil {
		t.Fatal(err)
	}
	input[0] = 9
	if got[0] != 1 {
		t.Fatal("readback data still aliases native memory")
	}
}

func TestWFPStatusPreservesNativeCode(t *testing.T) {
	if err := wfpStatus("read", 0); err != nil {
		t.Fatal(err)
	}
	err := wfpStatus("read", 0x80320002)
	if !errors.Is(err, syscall.Errno(0x80320002)) {
		t.Fatalf("native WFP error code lost: %v", err)
	}
}

func TestWFPABIPrefixOffsets(t *testing.T) {
	if unsafe.Sizeof(windows.GUID{}) != 16 || unsafe.Sizeof(fwpmAction0{}) != 20 {
		t.Fatal("GUID or FWPM_ACTION0 ABI size changed")
	}
	if unsafe.Sizeof(uintptr(0)) != 8 {
		t.Skipf("native readback ABI requires separate verification on %s", runtime.GOARCH)
	}
	if got := unsafe.Offsetof(fwpmProvider0{}.ProviderData); got != 40 {
		t.Fatalf("FWPM_PROVIDER0.providerData offset = %d, want 40", got)
	}
	if got := unsafe.Offsetof(fwpmSubLayer0{}.ProviderKey); got != 40 {
		t.Fatalf("FWPM_SUBLAYER0.providerKey offset = %d, want 40", got)
	}
	if got := unsafe.Offsetof(fwpmSubLayer0{}.Weight); got != 64 {
		t.Fatalf("FWPM_SUBLAYER0.weight offset = %d, want 64", got)
	}
	if got := unsafe.Offsetof(fwpmFilter0Prefix{}.LayerKey); got != 64 {
		t.Fatalf("FWPM_FILTER0.layerKey offset = %d, want 64", got)
	}
	if got := unsafe.Offsetof(fwpmFilter0Prefix{}.NumFilterConditions); got != 112 {
		t.Fatalf("FWPM_FILTER0.numFilterConditions offset = %d, want 112", got)
	}
	if got := unsafe.Offsetof(fwpmFilter0Prefix{}.Action); got != 128 {
		t.Fatalf("FWPM_FILTER0.action offset = %d, want 128", got)
	}
}

func TestInspectMissingObjectsReadOnlyIntegration(t *testing.T) {
	if os.Getenv("DROPO_WFP_READBACK_INTEGRATION") != "1" {
		t.Skip("set DROPO_WFP_READBACK_INTEGRATION=1 for a read-only BFE smoke test")
	}
	_, err := Inspect(ReadbackKeys{
		Provider: testGUID(0xd0a0ff01),
		SubLayer: testGUID(0xd0a0ff02),
		Filters:  []windows.GUID{testGUID(0xd0a0ff03)},
	})
	if errors.Is(err, syscall.ERROR_ACCESS_DENIED) {
		t.Skipf("read-only WFP transaction requires elevated BFE rights: %v", err)
	}
	if err == nil || !strings.Contains(err.Error(), "FwpmProviderGetByKey0") {
		t.Fatalf("expected missing provider from live BFE, got %v", err)
	}
}
