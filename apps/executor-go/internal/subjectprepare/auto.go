package subjectprepare

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

type Auto struct {
	Rails *RailsDB
}

func NewAuto() *Auto {
	return &Auto{Rails: NewRailsDB()}
}

func (p *Auto) Prepare(
	ctx context.Context,
	request protocol.RequestV1,
	role string,
	root string,
	runtimeEnv map[string]string,
) (map[string]string, error) {
	rails := prepareRegularFile(filepath.Join(root, "config", "environment.rb"))
	node := prepareRegularFile(filepath.Join(root, "package.json"))
	switch {
	case rails && node:
		return nil, errors.New("ambiguous subject runtime during subject preparation")
	case rails:
		return p.Rails.Prepare(ctx, request, role, root, runtimeEnv)
	case node:
		result := make(map[string]string, len(runtimeEnv))
		for key, value := range runtimeEnv {
			result[key] = value
		}
		return result, nil
	default:
		return nil, fmt.Errorf("unsupported subject runtime at %s", root)
	}
}

func prepareRegularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
