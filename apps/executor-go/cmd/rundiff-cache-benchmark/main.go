package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/bootstrap"
)

type bootstrapper interface {
	Bootstrap(context.Context, string, string) (map[string]string, error)
}

type sample struct {
	Pair         int     `json:"pair"`
	Runtime      string  `json:"runtime"`
	CacheKey     string  `json:"cache_key"`
	ColdSeed     string  `json:"cold_seed"`
	WarmSeed     string  `json:"warm_seed"`
	ColdMillis   float64 `json:"cold_ms"`
	WarmMillis   float64 `json:"warm_ms"`
	SpeedupRatio float64 `json:"cold_over_warm_ratio"`
}

type summary struct {
	Runtime        string  `json:"runtime"`
	Pairs          int     `json:"pairs"`
	ColdMedianMS   float64 `json:"cold_median_ms"`
	ColdP95MS      float64 `json:"cold_p95_ms"`
	WarmMedianMS   float64 `json:"warm_median_ms"`
	WarmP95MS      float64 `json:"warm_p95_ms"`
	MedianSpeedupX float64 `json:"median_cold_over_warm_ratio"`
}

type report struct {
	SchemaVersion string  `json:"schema_version"`
	Root          string  `json:"root"`
	Namespace     string  `json:"namespace"`
	Samples       []sample `json:"samples"`
	Summary       summary `json:"summary"`
}

func main() {
	os.Exit(run())
}

func run() int {
	var (
		root       = flag.String("root", ".", "Subject root containing dependency manifests")
		toolRoot   = flag.String("tool-root", ".", "RunDiff tool root used for default cache placement")
		runtimeArg = flag.String("runtime", "auto", "Subject runtime: auto, ruby, or node")
		pairs      = flag.Int("pairs", 3, "Cold/warm pairs to measure")
		cacheRoot  = flag.String("cache-root", "", "Benchmark cache root; defaults to a temporary directory")
		namespace  = flag.String("namespace", "benchmark", "Dependency cache trust namespace")
		output     = flag.String("output", "", "Optional JSON report path")
		timeout    = flag.Duration("timeout", 10*time.Minute, "Overall benchmark timeout")
	)
	flag.Parse()

	if *pairs < 1 || *pairs > 10 {
		fmt.Fprintln(os.Stderr, "--pairs must be between 1 and 10")
		return 2
	}
	if *runtimeArg != "auto" && *runtimeArg != "ruby" && *runtimeArg != "node" {
		fmt.Fprintln(os.Stderr, "--runtime must be auto, ruby, or node")
		return 2
	}

	absoluteRoot, err := filepath.Abs(*root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolve subject root: %v\n", err)
		return 1
	}
	absoluteToolRoot, err := filepath.Abs(*toolRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolve tool root: %v\n", err)
		return 1
	}

	benchmarkCacheRoot := *cacheRoot
	removeCacheRoot := false
	if benchmarkCacheRoot == "" {
		benchmarkCacheRoot, err = os.MkdirTemp("", "rundiff-dependency-cache-benchmark-*")
		if err != nil {
			fmt.Fprintf(os.Stderr, "create benchmark cache root: %v\n", err)
			return 1
		}
		removeCacheRoot = true
	} else {
		benchmarkCacheRoot, err = filepath.Abs(benchmarkCacheRoot)
		if err != nil {
			fmt.Fprintf(os.Stderr, "resolve benchmark cache root: %v\n", err)
			return 1
		}
	}
	if removeCacheRoot {
		defer os.RemoveAll(benchmarkCacheRoot)
	}

	restoreCacheRoot := replaceEnv("RUNDIFF_DEPENDENCY_CACHE_ROOT", "")
	defer restoreCacheRoot()
	restoreNamespace := replaceEnv("RUNDIFF_DEPENDENCY_CACHE_NAMESPACE", *namespace)
	defer restoreNamespace()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	samples := make([]sample, 0, *pairs)
	for pair := 1; pair <= *pairs; pair++ {
		pairCacheRoot := filepath.Join(benchmarkCacheRoot, fmt.Sprintf("pair-%02d", pair))
		if err := os.RemoveAll(pairCacheRoot); err != nil {
			fmt.Fprintf(os.Stderr, "reset pair cache root: %v\n", err)
			return 1
		}
		if err := os.MkdirAll(pairCacheRoot, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "create pair cache root: %v\n", err)
			return 1
		}
		if err := os.Setenv("RUNDIFF_DEPENDENCY_CACHE_ROOT", pairCacheRoot); err != nil {
			fmt.Fprintf(os.Stderr, "set cache root: %v\n", err)
			return 1
		}

		subjectBootstrapper := newBootstrapper(*runtimeArg, absoluteToolRoot)

		coldStarted := time.Now()
		coldEnv, err := subjectBootstrapper.Bootstrap(ctx, "base", absoluteRoot)
		coldDuration := time.Since(coldStarted)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pair %d cold bootstrap: %v\n", pair, err)
			return 1
		}

		warmStarted := time.Now()
		warmEnv, err := subjectBootstrapper.Bootstrap(ctx, "candidate", absoluteRoot)
		warmDuration := time.Since(warmStarted)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pair %d warm bootstrap: %v\n", pair, err)
			return 1
		}

		if coldEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"] == "" ||
			coldEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"] != warmEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"] {
			fmt.Fprintf(os.Stderr, "pair %d did not reuse one dependency cache identity\n", pair)
			return 1
		}
		if coldEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"] != "miss" {
			fmt.Fprintf(
				os.Stderr,
				"pair %d cold seed = %q, want miss\n",
				pair,
				coldEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"],
			)
			return 1
		}
		if warmEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"] != "hit" {
			fmt.Fprintf(
				os.Stderr,
				"pair %d warm seed = %q, want hit\n",
				pair,
				warmEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"],
			)
			return 1
		}

		runtimeName := detectedRuntime(*runtimeArg, warmEnv)
		coldMS := durationMilliseconds(coldDuration)
		warmMS := durationMilliseconds(warmDuration)
		ratio := 0.0
		if warmMS > 0 {
			ratio = coldMS / warmMS
		}

		samples = append(samples, sample{
			Pair:         pair,
			Runtime:      runtimeName,
			CacheKey:     coldEnv["RUNDIFF_DEPENDENCY_CACHE_KEY"],
			ColdSeed:     coldEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"],
			WarmSeed:     warmEnv["RUNDIFF_DEPENDENCY_CACHE_SEED"],
			ColdMillis:   coldMS,
			WarmMillis:   warmMS,
			SpeedupRatio: ratio,
		})
	}

	result := report{
		SchemaVersion: "1",
		Root:          absoluteRoot,
		Namespace:     *namespace,
		Samples:       samples,
		Summary:       summarize(samples),
	}
	body, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "encode benchmark report: %v\n", err)
		return 1
	}
	body = append(body, '\n')
	if *output != "" {
		if err := os.MkdirAll(filepath.Dir(*output), 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "create report directory: %v\n", err)
			return 1
		}
		if err := os.WriteFile(*output, body, 0o600); err != nil {
			fmt.Fprintf(os.Stderr, "write benchmark report: %v\n", err)
			return 1
		}
	}
	if _, err := os.Stdout.Write(body); err != nil {
		fmt.Fprintf(os.Stderr, "write benchmark output: %v\n", err)
		return 1
	}
	return 0
}

func newBootstrapper(runtimeName, toolRoot string) bootstrapper {
	switch runtimeName {
	case "ruby":
		return bootstrap.NewRubyBundle(toolRoot)
	case "node":
		return bootstrap.NewNodeNPM(toolRoot)
	default:
		return bootstrap.NewAuto(toolRoot)
	}
}

func detectedRuntime(requested string, env map[string]string) string {
	if requested != "auto" {
		return requested
	}
	if env["RUNDIFF_SUBJECT_NODE_VERSION"] != "" {
		return "node"
	}
	if env["RUNDIFF_SUBJECT_RUBY_VERSION"] != "" {
		return "ruby"
	}
	return "unknown"
}

func durationMilliseconds(value time.Duration) float64 {
	return math.Round((float64(value)/float64(time.Millisecond))*1000) / 1000
}

func summarize(samples []sample) summary {
	cold := make([]float64, 0, len(samples))
	warm := make([]float64, 0, len(samples))
	ratios := make([]float64, 0, len(samples))
	runtimeName := ""
	for _, item := range samples {
		if runtimeName == "" {
			runtimeName = item.Runtime
		}
		cold = append(cold, item.ColdMillis)
		warm = append(warm, item.WarmMillis)
		ratios = append(ratios, item.SpeedupRatio)
	}
	return summary{
		Runtime:        runtimeName,
		Pairs:          len(samples),
		ColdMedianMS:   percentile(cold, 0.50),
		ColdP95MS:      percentile(cold, 0.95),
		WarmMedianMS:   percentile(warm, 0.50),
		WarmP95MS:      percentile(warm, 0.95),
		MedianSpeedupX: percentile(ratios, 0.50),
	}
}

func percentile(values []float64, fraction float64) float64 {
	if len(values) == 0 {
		return 0
	}
	ordered := append([]float64{}, values...)
	sort.Float64s(ordered)
	index := int(math.Ceil(fraction*float64(len(ordered)))) - 1
	if index < 0 {
		index = 0
	}
	if index >= len(ordered) {
		index = len(ordered) - 1
	}
	return ordered[index]
}

func replaceEnv(key, value string) func() {
	previous, existed := os.LookupEnv(key)
	if value == "" {
		_ = os.Unsetenv(key)
	} else {
		_ = os.Setenv(key, value)
	}
	return func() {
		if existed {
			_ = os.Setenv(key, previous)
		} else {
			_ = os.Unsetenv(key)
		}
	}
}
