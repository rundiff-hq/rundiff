package bootstrap

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var versionPattern = regexp.MustCompile(`^(\d+)\.(\d+)`)

type CommandRunner interface {
	Run(context.Context, string, map[string]string, []string) ([]byte, error)
}

type OSCommandRunner struct{}

func (OSCommandRunner) Run(
	ctx context.Context,
	dir string,
	explicit map[string]string,
	command []string,
) ([]byte, error) {
	if len(command) == 0 {
		return nil, errors.New("bootstrap command is required")
	}

	cmd := exec.CommandContext(ctx, command[0], command[1:]...)
	cmd.Dir = dir
	cmd.Env = safeHostEnvironment()
	keys := make([]string, 0, len(explicit))
	for key := range explicit {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		cmd.Env = append(cmd.Env, key+"="+explicit[key])
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("bootstrap command %q failed: %w", command[0], err)
	}
	return output, nil
}

type RubyBundle struct {
	ToolRoot string
	Runner   CommandRunner
}

func NewRubyBundle(toolRoot string) *RubyBundle {
	return &RubyBundle{
		ToolRoot: toolRoot,
		Runner:   OSCommandRunner{},
	}
}

func (b *RubyBundle) Bootstrap(
	ctx context.Context,
	_ string,
	root string,
) (map[string]string, error) {
	if subjectIdentityEnabled() {
		return nil, errors.New("Go-native Ruby bootstrap does not yet support subject uid/gid isolation")
	}

	gemfile := filepath.Join(root, "Gemfile")
	lockfile := filepath.Join(root, "Gemfile.lock")
	if !fileExists(gemfile) {
		return nil, fmt.Errorf("Rails subject is missing Gemfile at %s", gemfile)
	}
	if !fileExists(lockfile) {
		return nil, errors.New("Rails subject must commit Gemfile.lock for reproducible execution")
	}

	lockContents, err := os.ReadFile(lockfile)
	if err != nil {
		return nil, err
	}
	originalDigest := sha256.Sum256(lockContents)

	rubyOutput, err := b.runner().Run(
		ctx,
		root,
		nil,
		[]string{"ruby", "-e", "print RUBY_VERSION"},
	)
	if err != nil {
		return nil, err
	}
	rubyVersion := strings.TrimSpace(string(rubyOutput))
	requestedRubyVersion, err := requestedRubyVersion(root, lockContents)
	if err != nil {
		return nil, err
	}
	if requestedRubyVersion != "" &&
		majorMinor(requestedRubyVersion) != majorMinor(rubyVersion) {
		return nil, fmt.Errorf(
			"Rails subject requires Ruby %s but executor provides Ruby %s; v0.1 requires the same Ruby major/minor line",
			requestedRubyVersion,
			rubyVersion,
		)
	}

	cacheKey := fmt.Sprintf(
		"ruby-%s-%x",
		majorMinor(rubyVersion),
		originalDigest[:10],
	)
	cacheRoot := filepath.Join(b.ToolRoot, "tmp", "rundiff", "bundles", cacheKey)
	if err := os.MkdirAll(cacheRoot, 0o755); err != nil {
		return nil, err
	}

	env := map[string]string{
		"BUNDLE_GEMFILE":                gemfile,
		"BUNDLE_PATH":                   filepath.Join(cacheRoot, "gems"),
		"BUNDLE_APP_CONFIG":             filepath.Join(cacheRoot, "config"),
		"BUNDLE_DEPLOYMENT":             "true",
		"BUNDLE_FROZEN":                 "true",
		"RUNDIFF_SUBJECT_RUBY_VERSION":  firstNonEmpty(requestedRubyVersion, rubyVersion),
		"RUNDIFF_SUBJECT_BUNDLE_SEED":   "miss",
	}

	bundlerVersion := bundledWith(lockContents)
	if bundlerVersion != "" {
		env["RUNDIFF_SUBJECT_BUNDLER_VERSION"] = bundlerVersion
		if _, err := b.runner().Run(
			ctx,
			root,
			nil,
			[]string{"gem", "list", "-i", "bundler", "-v", bundlerVersion},
		); err != nil {
			if _, installErr := b.runner().Run(
				ctx,
				root,
				nil,
				[]string{"gem", "install", "bundler", "-v", bundlerVersion, "--no-document"},
			); installErr != nil {
				return nil, installErr
			}
		}
	} else {
		env["RUNDIFF_SUBJECT_BUNDLER_VERSION"] = "default"
	}

	bundleCommand := []string{"bundle"}
	if bundlerVersion != "" {
		bundleCommand = append(bundleCommand, "_"+bundlerVersion+"_")
	}

	check := append(append([]string{}, bundleCommand...), "check")
	if _, err := b.runner().Run(ctx, root, env, check); err != nil {
		install := append(
			append([]string{}, bundleCommand...),
			"install",
			"--jobs",
			"4",
			"--retry",
			"3",
		)
		if _, installErr := b.runner().Run(ctx, root, env, install); installErr != nil {
			return nil, installErr
		}
	}

	actualContents, err := os.ReadFile(lockfile)
	if err != nil {
		return nil, err
	}
	actualDigest := sha256.Sum256(actualContents)
	if actualDigest != originalDigest {
		return nil, errors.New("Customer Gemfile.lock changed during dependency bootstrap")
	}

	return env, nil
}

func (b *RubyBundle) runner() CommandRunner {
	if b.Runner != nil {
		return b.Runner
	}
	return OSCommandRunner{}
}

func requestedRubyVersion(root string, lockContents []byte) (string, error) {
	versionFile := filepath.Join(root, ".ruby-version")
	if body, err := os.ReadFile(versionFile); err == nil {
		value := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(string(body)), "ruby-"))
		if value != "" {
			if majorMinor(value) == "" {
				return "", fmt.Errorf("unsupported Ruby version declaration %q", value)
			}
			return value, nil
	} else if !os.IsNotExist(err) {
		return "", err
	}

	lines := strings.Split(string(lockContents), "\n")
	for index, line := range lines {
		if strings.TrimSpace(line) != "RUBY VERSION" || index+1 >= len(lines) {
			continue
		}
		fields := strings.Fields(strings.TrimSpace(lines[index+1]))
		if len(fields) >= 2 && fields[0] == "ruby" {
			value := fields[1]
			if majorMinor(value) == "" {
				return "", fmt.Errorf("unsupported Ruby version declaration %q", value)
			}
			return value, nil
		}
	}
	return "", nil
}

func bundledWith(lockContents []byte) string {
	lines := strings.Split(string(lockContents), "\n")
	for index, line := range lines {
		if strings.TrimSpace(line) == "BUNDLED WITH" && index+1 < len(lines) {
			return strings.TrimSpace(lines[index+1])
		}
	}
	return ""
}

func majorMinor(version string) string {
	match := versionPattern.FindStringSubmatch(strings.TrimSpace(version))
	if len(match) != 3 {
		return ""
	}
	return match[1] + "." + match[2]
}

func safeHostEnvironment() []string {
	keys := []string{
		"PATH",
		"HOME",
		"TMPDIR",
		"LANG",
		"LC_ALL",
		"LC_CTYPE",
		"SSL_CERT_FILE",
		"SSL_CERT_DIR",
	}
	environment := make([]string, 0, len(keys))
	for _, key := range keys {
		if value, ok := os.LookupEnv(key); ok {
			environment = append(environment, key+"="+value)
		}
	}
	return environment
}

func subjectIdentityEnabled() bool {
	for _, key := range []string{
		"RUNDIFF_SUBJECT_UID",
		"RUNDIFF_SUBJECT_GID",
		"RUNDIFF_SUBJECT_HOME",
		"RUNDIFF_SUBJECT_USER",
	} {
		if os.Getenv(key) != "" {
			return true
		}
	}
	return false
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
