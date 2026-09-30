package boxd

import (
	"encoding/json"
	"testing"
)

func int64Pointer(value int64) *int64 {
	return &value
}

func TestSummarizeInt64MetricUsesObservedMedianAndRange(t *testing.T) {
	got := summarizeInt64Metric([]int64{9, 2, 7, 4, 5})
	if got.Count != 5 || got.Median != 5 || got.Min != 2 || got.Max != 9 {
		t.Fatalf("summary = %#v", got)
	}
}

func TestSummarizeResourceEconomicsSamplesUsesBothRoles(t *testing.T) {
	samples := []resourceLifecycleSample{
		{
			ForkReadyMS:        10,
			RoleCriticalPathMS: 20,
			CleanupMS:          5,
			Baseline: guestResourceSnapshot{
				GuestMemUsedProxyBytes: 100,
				ProcessRSSSumBytes:     40,
				RootFSUsedBytes:        1000,
				PostgresVolumeBytes:    int64Pointer(200),
				PostgresSizeRWBytes:    int64Pointer(10),
			},
			Candidate: guestResourceSnapshot{
				GuestMemUsedProxyBytes: 120,
				ProcessRSSSumBytes:     50,
				RootFSUsedBytes:        1100,
				PostgresVolumeBytes:    int64Pointer(220),
				PostgresSizeRWBytes:    int64Pointer(12),
			},
		},
		{
			ForkReadyMS:        12,
			RoleCriticalPathMS: 22,
			CleanupMS:          6,
			Baseline: guestResourceSnapshot{
				GuestMemUsedProxyBytes: 140,
				ProcessRSSSumBytes:     60,
				RootFSUsedBytes:        1200,
				PostgresVolumeBytes:    int64Pointer(240),
				PostgresSizeRWBytes:    int64Pointer(14),
			},
			Candidate: guestResourceSnapshot{
				GuestMemUsedProxyBytes: 160,
				ProcessRSSSumBytes:     70,
				RootFSUsedBytes:        1300,
				PostgresVolumeBytes:    int64Pointer(260),
				PostgresSizeRWBytes:    int64Pointer(16),
			},
		},
	}

	got := summarizeResourceEconomicsSamples(samples)
	if got.ChildGuestMemUsedProxyBytes.Count != 4 ||
		got.ChildGuestMemUsedProxyBytes.Median != 140 ||
		got.ChildGuestMemUsedProxyBytes.Min != 100 ||
		got.ChildGuestMemUsedProxyBytes.Max != 160 {
		t.Fatalf("memory summary = %#v", got.ChildGuestMemUsedProxyBytes)
	}
	if got.ForkReadyMS.Median != 12 || got.RoleCriticalPathMS.Median != 22 {
		t.Fatalf("lifecycle summary = %#v", got)
	}
}

func TestResourceRoleEnvelopeUsesExplicitCaptureAndResourceObjects(t *testing.T) {
	body := []byte(
		"{\"Capture\":{\"status\":\"passed\"},\"Resource\":{" +
			"\"CollectedAtUTC\":\"2026-09-30T00:00:00Z\"," +
			"\"Stage\":\"role_active\",\"Role\":\"baseline\"," +
			"\"GuestMemTotalBytes\":1000,\"GuestMemAvailableBytes\":400," +
			"\"GuestMemUsedProxyBytes\":600,\"ProcessRSSSumBytes\":200," +
			"\"RootFSUsedBytes\":300}}",
	)
	var envelope resourceRoleEnvelope
	if err := json.Unmarshal(body, &envelope); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if !json.Valid(envelope.Capture) {
		t.Fatal("capture is invalid JSON")
	}
	if envelope.Resource.Stage != "role_active" ||
		envelope.Resource.Role != "baseline" ||
		envelope.Resource.GuestMemUsedProxyBytes != 600 {
		t.Fatalf("resource = %#v", envelope.Resource)
	}
}
