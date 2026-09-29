package golden

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
)

const SchemaVersion = "1"

type Spec struct {
	SchemaVersion         string `json:"schema_version"`
	Provider              string `json:"provider"`
	BaseImage             string `json:"base_image"`
	Repository            string `json:"repository"`
	TrustedSource         string `json:"trusted_source"`
	ToolRevision          string `json:"tool_revision"`
	RuntimeIdentity       string `json:"runtime_identity"`
	DependencyLockDigest  string `json:"dependency_lock_digest"`
	ServiceTopologyDigest string `json:"service_topology_digest"`
}

func (spec Spec) Normalize() Spec {
	result := spec
	if result.SchemaVersion == "" {
		result.SchemaVersion = SchemaVersion
	}
	result.Provider = strings.TrimSpace(result.Provider)
	result.BaseImage = strings.TrimSpace(result.BaseImage)
	result.Repository = strings.TrimSpace(result.Repository)
	result.TrustedSource = strings.TrimSpace(result.TrustedSource)
	result.ToolRevision = strings.TrimSpace(result.ToolRevision)
	result.RuntimeIdentity = strings.TrimSpace(result.RuntimeIdentity)
	result.DependencyLockDigest = strings.TrimSpace(result.DependencyLockDigest)
	result.ServiceTopologyDigest = strings.TrimSpace(result.ServiceTopologyDigest)
	return result
}

func (spec Spec) Validate() error {
	spec = spec.Normalize()
	values := []struct {
		name  string
		value string
	}{
		{"schema_version", spec.SchemaVersion},
		{"provider", spec.Provider},
		{"base_image", spec.BaseImage},
		{"repository", spec.Repository},
		{"trusted_source", spec.TrustedSource},
		{"tool_revision", spec.ToolRevision},
		{"runtime_identity", spec.RuntimeIdentity},
		{"dependency_lock_digest", spec.DependencyLockDigest},
		{"service_topology_digest", spec.ServiceTopologyDigest},
	}
	for _, item := range values {
		if item.value == "" {
			return errors.New("golden " + item.name + " is required")
		}
	}
	return nil
}

func (spec Spec) Fingerprint() (string, error) {
	spec = spec.Normalize()
	if err := spec.Validate(); err != nil {
		return "", err
	}
	body, err := json.Marshal(spec)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:]), nil
}

func MachineName(fingerprint string) string {
	const prefixLength = 20
	value := strings.ToLower(strings.TrimSpace(fingerprint))
	if len(value) > prefixLength {
		value = value[:prefixLength]
	}
	return "rundiff-golden-" + value
}
