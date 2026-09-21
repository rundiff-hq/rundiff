package bootstrap

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type Auto struct {
	Rails *RubyBundle
	Node  *NodeNPM
}

func NewAuto(toolRoot string) *Auto {
	return &Auto{
		Rails: NewRubyBundle(toolRoot),
		Node:  NewNodeNPM(toolRoot),
	}
}

func (a *Auto) Bootstrap(ctx context.Context, role, root string) (map[string]string, error) {
	rails := regularFile(filepath.Join(root, "config", "environment.rb"))
	node := regularFile(filepath.Join(root, "package.json"))
	switch {
	case rails && node:
		return nil, errors.New("ambiguous subject runtime: both Rails and Node application markers are present")
	case rails:
		return a.Rails.Bootstrap(ctx, role, root)
	case node:
		return a.Node.Bootstrap(ctx, role, root)
	default:
		return nil, fmt.Errorf("unsupported subject runtime at %s", root)
	}
}

func regularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
