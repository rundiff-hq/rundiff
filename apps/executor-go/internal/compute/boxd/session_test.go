package boxd

import (
	"testing"
)

type closingFakeSDKBridgeRunner struct {
	fakeSDKBridgeRunner
	closeCount int
}

func (runner *closingFakeSDKBridgeRunner) Close() error {
	runner.closeCount++
	return nil
}

func TestSDKCloseClosesSessionRunner(t *testing.T) {
	runner := &closingFakeSDKBridgeRunner{}
	client := &SDK{runner: runner}

	if err := client.Close(); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
	if runner.closeCount != 1 {
		t.Fatalf("close count = %d, want 1", runner.closeCount)
	}
}

func TestSDKCloseIsNoOpForShortLivedRunner(t *testing.T) {
	client := &SDK{runner: &fakeSDKBridgeRunner{}}
	if err := client.Close(); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
}

func TestNewSessionSDKReportsMissingNodeBinary(t *testing.T) {
	client, err := NewSessionSDK(
		"definitely-not-a-real-node-binary-rundiff",
		"sdkbridge/session.mjs",
	)
	if err == nil {
		if client != nil {
			_ = client.Close()
		}
		t.Fatal("expected session start error")
	}
}
