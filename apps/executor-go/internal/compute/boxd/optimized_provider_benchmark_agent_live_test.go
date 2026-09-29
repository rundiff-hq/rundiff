package boxd

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

const optimizedProviderAgentPrefix = "RUNDIFF_AGENT "

type optimizedProviderAgentCommand struct {
	Op               string `json:"op"`
	Pair             int    `json:"pair,omitempty"`
	SequencePosition int    `json:"sequence_position,omitempty"`
}

type optimizedProviderAgentReady struct {
	Type            string `json:"type"`
	CreateGoldenMS  int64  `json:"create_golden_ms"`
	PrepareGoldenMS int64  `json:"prepare_golden_ms"`
	ParentStartedAt string `json:"parent_started_at"`
}

type optimizedProviderAgentSample struct {
	Type   string             `json:"type"`
	Sample behavioralDBSample `json:"sample"`
}

type optimizedProviderAgentClosed struct {
	Type            string `json:"type"`
	GoldenCleanupMS int64  `json:"golden_cleanup_ms"`
}

func TestLiveOptimizedProviderBenchmarkAgent(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the optimized Boxd benchmark agent")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required for the optimized Boxd benchmark agent")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	if proofID == "" {
		t.Fatal("RUNDIFF_BOXD_PROOF_ID is required for the optimized Boxd benchmark agent")
	}
	toolSHA := strings.TrimSpace(os.Getenv("RUNDIFF_BOXD_TOOL_SHA"))
	if toolSHA == "" {
		t.Fatal("RUNDIFF_BOXD_TOOL_SHA is required for the optimized Boxd benchmark agent")
	}

	client, err := NewSessionPairSDK(
		"node",
		"sdkbridge/session.mjs",
		"sdkbridge/bridge.mjs",
	)
	if err != nil {
		t.Fatalf("start benchmark PairSDK: %v", err)
	}
	defer func() {
		if closeErr := client.Close(); closeErr != nil {
			t.Errorf("close benchmark PairSDK: %v", closeErr)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()

	parentName := "rundiff-ob-" + proofID

	createStarted := time.Now()
	parent, err := client.Create(ctx, parentName, true)
	if err != nil {
		t.Fatalf("create optimized benchmark golden: %v", err)
	}
	createMS := time.Since(createStarted).Milliseconds()

	parentRemoved := false
	defer func() {
		if !parentRemoved {
			removeMachine(t, client, parent)
		}
	}()

	prepareStarted := time.Now()
	if _, err := execBoxdOK(ctx, client, parent, []string{
		"bash", "-lc", boxdGoldenPrepareScript, "rundiff-golden",
		toolSHA, boxdFixtureRepository, boxdFixtureBaselineSHA, boxdFixtureCandidateSHA,
	}); err != nil {
		t.Fatalf("prepare optimized benchmark golden: %v", err)
	}
	if _, err := execBoxdOK(ctx, client, parent, []string{
		"bash", "-lc", inheritedBehavioralPostgresPrepareScript,
	}); err != nil {
		t.Fatalf("start PostgreSQL in optimized benchmark golden: %v", err)
	}
	if err := waitRunningPostgres(ctx, client, parent); err != nil {
		t.Fatalf("optimized benchmark PostgreSQL not ready: %v", err)
	}
	prepareMS := time.Since(prepareStarted).Milliseconds()
	parentStartedAt := postgresContainerStartedAt(t, ctx, client, parent)

	writer := bufio.NewWriter(os.Stdout)
	emitOptimizedProviderAgentMessage(t, writer, optimizedProviderAgentReady{
		Type:            "ready",
		CreateGoldenMS:  createMS,
		PrepareGoldenMS: prepareMS,
		ParentStartedAt: parentStartedAt,
	})

	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var command optimizedProviderAgentCommand
		if err := json.Unmarshal(scanner.Bytes(), &command); err != nil {
			t.Fatalf("decode benchmark agent command: %v", err)
		}

		switch command.Op {
		case "run":
			if command.Pair < 1 {
				t.Fatalf("benchmark agent pair must be positive")
			}
			if command.SequencePosition != 1 && command.SequencePosition != 2 {
				t.Fatalf("benchmark agent sequence_position must be 1 or 2")
			}

			sample := runBehavioralDBSample(
				t,
				ctx,
				client,
				parent,
				parentStartedAt,
				behavioralDBInherited,
				command.Pair,
				command.SequencePosition,
				proofID,
			)
			emitOptimizedProviderAgentMessage(t, writer, optimizedProviderAgentSample{
				Type:   "sample",
				Sample: sample,
			})
		case "close":
			cleanupStarted := time.Now()
			removeMachine(t, client, parent)
			parentRemoved = true
			emitOptimizedProviderAgentMessage(t, writer, optimizedProviderAgentClosed{
				Type:            "closed",
				GoldenCleanupMS: time.Since(cleanupStarted).Milliseconds(),
			})
			return
		default:
			t.Fatalf("unsupported benchmark agent op %q", command.Op)
		}
	}

	if err := scanner.Err(); err != nil {
		t.Fatalf("read benchmark agent command: %v", err)
	}
	t.Fatal("benchmark agent stdin closed before explicit close command")
}

func emitOptimizedProviderAgentMessage(
	t *testing.T,
	writer *bufio.Writer,
	message any,
) {
	t.Helper()

	body, err := json.Marshal(message)
	if err != nil {
		t.Fatalf("encode benchmark agent response: %v", err)
	}
	if _, err := fmt.Fprintf(
		writer,
		"%s%s\n",
		optimizedProviderAgentPrefix,
		body,
	); err != nil {
		t.Fatalf("write benchmark agent response: %v", err)
	}
	if err := writer.Flush(); err != nil {
		t.Fatalf("flush benchmark agent response: %v", err)
	}
}
