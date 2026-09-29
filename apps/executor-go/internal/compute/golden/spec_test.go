package golden

import "testing"

func testSpec() Spec {
	return Spec{
		Provider:              "boxd",
		BaseImage:             "ubuntu-24.04",
		Repository:            "rundiff-hq/example-node-express-postgres",
		TrustedSource:         "e90bbe1a7055dece4f1cdffe0d5ef9fb3a5b69fb",
		ToolRevision:          "tool-sha",
		RuntimeIdentity:       "node-24+npm-11",
		DependencyLockDigest:  "lock-sha256",
		ServiceTopologyDigest: "postgres17+node-http-v1",
	}
}

func TestFingerprintStableForEquivalentSpecs(t *testing.T) {
	left, err := testSpec().Fingerprint()
	if err != nil {
		t.Fatalf("Fingerprint returned error: %v", err)
	}

	rightSpec := testSpec()
	rightSpec.SchemaVersion = SchemaVersion
	right, err := rightSpec.Fingerprint()
	if err != nil {
		t.Fatalf("Fingerprint returned error: %v", err)
	}

	if left != right {
		t.Fatalf("fingerprints differ: %q != %q", left, right)
	}
}

func TestFingerprintChangesWhenPreparationIdentityChanges(t *testing.T) {
	base, err := testSpec().Fingerprint()
	if err != nil {
		t.Fatalf("Fingerprint returned error: %v", err)
	}

	cases := []struct {
		name   string
		mutate func(*Spec)
	}{
		{"base image", func(spec *Spec) { spec.BaseImage = "ubuntu-26.04" }},
		{"repository", func(spec *Spec) { spec.Repository = "rundiff-hq/other" }},
		{"trusted source", func(spec *Spec) { spec.TrustedSource = "other-base" }},
		{"tool revision", func(spec *Spec) { spec.ToolRevision = "other-tool" }},
		{"runtime", func(spec *Spec) { spec.RuntimeIdentity = "node-26+npm-12" }},
		{"lock digest", func(spec *Spec) { spec.DependencyLockDigest = "other-lock" }},
		{"service topology", func(spec *Spec) { spec.ServiceTopologyDigest = "redis+postgres" }},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			changed := testSpec()
			tc.mutate(&changed)
			got, err := changed.Fingerprint()
			if err != nil {
				t.Fatalf("Fingerprint returned error: %v", err)
			}
			if got == base {
				t.Fatalf("fingerprint did not change for %s", tc.name)
			}
		})
	}
}

func TestMachineNameUsesBoundedFingerprintPrefix(t *testing.T) {
	fingerprint, err := testSpec().Fingerprint()
	if err != nil {
		t.Fatalf("Fingerprint returned error: %v", err)
	}
	got := MachineName(fingerprint)
	if got != "rundiff-golden-"+fingerprint[:20] {
		t.Fatalf("machine name = %q", got)
	}
}

func TestValidateRejectsIncompleteSpec(t *testing.T) {
	spec := testSpec()
	spec.DependencyLockDigest = ""

	if err := spec.Validate(); err == nil {
		t.Fatal("expected validation error")
	}
}
