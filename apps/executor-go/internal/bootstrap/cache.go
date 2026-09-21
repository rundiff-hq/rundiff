package bootstrap

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type DependencyCacheEntry struct {
	Key       string
	Root      string
	Path      string
	Namespace string
}

func dependencyCacheEntry(
	toolRoot string,
	runtimeName string,
	runtimeVersion string,
	manager string,
	managerVersion string,
	lockContents []byte,
) DependencyCacheEntry {
	root := os.Getenv("RUNDIFF_DEPENDENCY_CACHE_ROOT")
	if root == "" {
		root = filepath.Join(toolRoot, "tmp", "rundiff", "dependency-cache", "v1")
	}
	namespace := os.Getenv("RUNDIFF_DEPENDENCY_CACHE_NAMESPACE")
	if namespace == "" {
		namespace = "local-trusted"
	}

	lockDigest := sha256.Sum256(lockContents)
	identity := strings.Join([]string{
		"v1",
		namespace,
		runtimeName,
		runtimeVersion,
		manager,
		managerVersion,
		runtime.GOOS,
		runtime.GOARCH,
		hex.EncodeToString(lockDigest[:]),
	}, "\n")
	keyDigest := sha256.Sum256([]byte(identity))
	key := fmt.Sprintf("%s-%s-%s", runtimeName, manager, hex.EncodeToString(keyDigest[:16]))

	return DependencyCacheEntry{
		Key:       key,
		Root:      root,
		Path:      filepath.Join(root, key),
		Namespace: namespace,
	}
}

func directoryHasEntries(path string) bool {
	entries, err := os.ReadDir(path)
	return err == nil && len(entries) > 0
}
