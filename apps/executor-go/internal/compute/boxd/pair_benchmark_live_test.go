package boxd

import (
	"context"
	"os"
	"sort"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/compute"
)

func TestLiveParallelForkBenchmark(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live Boxd pair fork benchmark")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the live Boxd pair fork benchmark")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the live Boxd pair fork benchmark")
	}

	client, err := NewSessionPairSDK(
		"node",
		"sdkbridge/session.mjs",
		"sdkbridge/bridge.mjs",
	)
	if err != nil {
		t.Fatalf("start pair SDK sessions: %v", err)
	}
	defer func() {
		if closeErr := client.Close(); closeErr != nil {
			t.Errorf("close pair SDK sessions: %v", closeErr)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	parentName := "rundiff-pbm-" + proofID
	parent, err := client.Create(ctx, parentName, true)
	if err != nil {
		t.Fatalf("create pair benchmark parent: %v", err)
	}
	defer removeMachine(t, client, parent)

	const samples = 5
	sequential := make([]int64, 0, samples)
	parallel := make([]int64, 0, samples)

	for sample := 1; sample <= samples; sample++ {
		runSequential := func() int64 {
			baselineName := benchmarkChildName("sb", sample, proofID)
			candidateName := benchmarkChildName("sc", sample, proofID)
			started := time.Now()
			pair, pairErr := compute.ForkPair(
				ctx,
				client.primary,
				parent.Name,
				baselineName,
				candidateName,
			)
			if pairErr != nil {
				t.Fatalf("sequential sample %d: %v", sample, pairErr)
			}
			elapsed := time.Since(started).Milliseconds()
			cleanupPair(t, client, pair)
			return elapsed
		}

		runParallel := func() int64 {
			baselineName := benchmarkChildName("pb", sample, proofID)
			candidateName := benchmarkChildName("pc", sample, proofID)
			started := time.Now()
			pair, pairErr := compute.ForkPair(
				ctx,
				client,
				parent.Name,
				baselineName,
				candidateName,
			)
			if pairErr != nil {
				t.Fatalf("parallel sample %d: %v", sample, pairErr)
			}
			elapsed := time.Since(started).Milliseconds()
			cleanupPair(t, client, pair)
			return elapsed
		}

		var first string
		var sequentialMS int64
		var parallelMS int64
		if sample%2 == 1 {
			first = "sequential"
			sequentialMS = runSequential()
			parallelMS = runParallel()
		} else {
			first = "parallel"
			parallelMS = runParallel()
			sequentialMS = runSequential()
		}

		sequential = append(sequential, sequentialMS)
		parallel = append(parallel, parallelMS)
		t.Logf(
			"provider.pair_benchmark.sample=%d first=%s sequential_ms=%d parallel_ms=%d",
			sample,
			first,
			sequentialMS,
			parallelMS,
		)
	}

	sequentialMedian := medianInt64(sequential)
	parallelMedian := medianInt64(parallel)
	t.Logf("provider.pair_benchmark.sequential_median_ms=%d", sequentialMedian)
	t.Logf("provider.pair_benchmark.parallel_median_ms=%d", parallelMedian)
	if parallelMedian > 0 {
		t.Logf(
			"provider.pair_benchmark.parallel_speedup=%.3f",
			float64(sequentialMedian)/float64(parallelMedian),
		)
	}
}

func benchmarkChildName(role string, sample int, proofID string) string {
	return "rundiff-" + role + string(rune('0'+sample)) + "-" + proofID
}

func medianInt64(values []int64) int64 {
	sorted := append([]int64(nil), values...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i] < sorted[j]
	})
	return sorted[len(sorted)/2]
}
