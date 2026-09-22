package bootstrap

import (
	"testing"
)

func TestDependencyCacheIdentityIsStableAndLockAddressed(t *testing.T) {
	t.Setenv("RUNDIFF_DEPENDENCY_CACHE_NAMESPACE", "rundiff-hq/rundiff")
	first := dependencyCacheEntry("/tool", "ruby", "3.4", "bundler", "4.0.13", []byte("lock-a"))
	second := dependencyCacheEntry("/tool", "ruby", "3.4", "bundler", "4.0.13", []byte("lock-a"))
	changed := dependencyCacheEntry("/tool", "ruby", "3.4", "bundler", "4.0.13", []byte("lock-b"))

	if first.Key != second.Key || first.Path != second.Path {
		t.Fatalf("same dependency identity must share cache: %#v %#v", first, second)
	}
	if first.Key == changed.Key {
		t.Fatalf("changed lockfile must change cache identity: %q", first.Key)
	}
	if first.Namespace != "rundiff-hq/rundiff" {
		t.Fatalf("namespace = %q", first.Namespace)
	}
}

func TestDependencyCacheIdentityIsNamespaceScoped(t *testing.T) {
	t.Setenv("RUNDIFF_DEPENDENCY_CACHE_NAMESPACE", "customer-a/repo")
	first := dependencyCacheEntry("/tool", "node", "v24.20.0", "npm", "11.19.0", []byte("same-lock"))
	t.Setenv("RUNDIFF_DEPENDENCY_CACHE_NAMESPACE", "customer-b/repo")
	second := dependencyCacheEntry("/tool", "node", "v24.20.0", "npm", "11.19.0", []byte("same-lock"))

	if first.Key == second.Key {
		t.Fatal("different trust namespaces must not share prepared dependency cache identity")
	}
}
