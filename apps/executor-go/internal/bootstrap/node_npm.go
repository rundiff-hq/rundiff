package bootstrap

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type NodeNPM struct {
	ToolRoot string
	Runner   CommandRunner
}

func NewNodeNPM(toolRoot string) *NodeNPM {
	return &NodeNPM{ToolRoot: toolRoot, Runner: OSCommandRunner{}}
}

func (b *NodeNPM) Bootstrap(ctx context.Context, _ string, root string) (map[string]string, error) {
	manifest := filepath.Join(root, "package.json")
	lockfile := filepath.Join(root, "package-lock.json")
	if !fileExists(manifest) {
		return nil, fmt.Errorf("Node subject is missing package.json at %s", manifest)
	}
	if !fileExists(lockfile) {
		return nil, errors.New("Node v1 requires committed package-lock.json for deterministic npm bootstrap")
	}
	manifestBefore, err := os.ReadFile(manifest)
	if err != nil {
		return nil, err
	}
	lockBefore, err := os.ReadFile(lockfile)
	if err != nil {
		return nil, err
	}
	manifestDigest := sha256.Sum256(manifestBefore)
	lockDigest := sha256.Sum256(lockBefore)

	nodeVersion, err := b.runner().Run(ctx, root, nil, []string{"node", "--version"})
	if err != nil {
		return nil, err
	}
	npmVersion, err := b.runner().Run(ctx, root, nil, []string{"npm", "--version"})
	if err != nil {
		return nil, err
	}
	nodeVersionString := string(bytes.TrimSpace(nodeVersion))
	npmVersionString := string(bytes.TrimSpace(npmVersion))
	cacheEntry := dependencyCacheEntry(
		firstNonEmpty(b.ToolRoot, root),
		"node",
		nodeVersionString,
		"npm",
		npmVersionString,
		lockBefore,
	)
	npmCache := filepath.Join(cacheEntry.Path, "npm")
	seed := "miss"
	if directoryHasEntries(npmCache) {
		seed = "hit"
	}
	if err := os.MkdirAll(npmCache, 0o755); err != nil {
		return nil, err
	}
	env := map[string]string{
		"NPM_CONFIG_CACHE":                    npmCache,
		"NPM_CONFIG_AUDIT":                    "false",
		"NPM_CONFIG_FUND":                     "false",
		"RUNDIFF_DEPENDENCY_CACHE_KEY":         cacheEntry.Key,
		"RUNDIFF_DEPENDENCY_CACHE_ROOT":        cacheEntry.Root,
		"RUNDIFF_DEPENDENCY_CACHE_NAMESPACE":   cacheEntry.Namespace,
		"RUNDIFF_DEPENDENCY_CACHE_SEED":        seed,
	}
	if _, err := b.runner().Run(
		ctx,
		root,
		env,
		[]string{"npm", "ci", "--ignore-scripts=false", "--prefer-offline"},
	); err != nil {
		return nil, err
	}

	manifestAfter, err := os.ReadFile(manifest)
	if err != nil {
		return nil, err
	}
	lockAfter, err := os.ReadFile(lockfile)
	if err != nil {
		return nil, err
	}
	if sha256.Sum256(manifestAfter) != manifestDigest {
		return nil, errors.New("customer package.json changed during npm bootstrap")
	}
	if sha256.Sum256(lockAfter) != lockDigest {
		return nil, errors.New("customer package-lock.json changed during npm bootstrap")
	}
	env["RUNDIFF_SUBJECT_NODE_VERSION"] = nodeVersionString
	env["RUNDIFF_SUBJECT_NPM_VERSION"] = npmVersionString
	return env, nil
}

func (b *NodeNPM) runner() CommandRunner {
	if b.Runner != nil {
		return b.Runner
	}
	return OSCommandRunner{}
}
