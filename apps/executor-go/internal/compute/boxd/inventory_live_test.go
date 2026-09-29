package boxd

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestLiveEnvironmentInventory(t *testing.T) {
	if os.Getenv("RUNDIFF_BOXD_LIVE") != "1" {
		t.Skip("set RUNDIFF_BOXD_LIVE=1 to run the live Boxd environment inventory")
	}
	if os.Getenv("BOXD_API_KEY") == "" {
		t.Fatal("BOXD_API_KEY is required")
	}

	proofID := sanitizeProofID(os.Getenv("RUNDIFF_BOXD_PROOF_ID"))
	client := NewSDK("node", "sdkbridge/bridge.mjs")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	machine, err := client.Create(ctx, "rundiff-i-"+proofID, true)
	if err != nil {
		t.Fatalf("create inventory machine: %v", err)
	}
	defer removeMachine(t, client, machine)

	result, err := client.Exec(ctx, machine, []string{
		"sh", "-lc",
		`set -eu
printf 'os='; . /etc/os-release; printf '%s %s\n' "$ID" "$VERSION_ID"
for tool in git node npm go docker psql postgres curl wget python3 ruby; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s=' "$tool"
    case "$tool" in
      node) node --version ;;
      npm) npm --version ;;
      go) go version ;;
      docker) docker --version ;;
      psql) psql --version ;;
      postgres) postgres --version ;;
      git) git --version ;;
      curl) curl --version | head -n1 ;;
      wget) wget --version | head -n1 ;;
      python3) python3 --version ;;
      ruby) ruby --version ;;
    esac
  else
    printf '%s=missing\n' "$tool"
  fi
done
printf 'uid='; id -u
`,
	})
	if err != nil {
		t.Fatalf("inventory exec: %v", err)
	}
	if result.ExitCode != 0 {
		t.Fatalf("inventory exit=%d stderr=%s", result.ExitCode, result.Stderr)
	}
	for _, line := range strings.Split(strings.TrimSpace(result.Stdout), "\n") {
		t.Log(line)
	}
}
