package comparison

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"strconv"
)

var countable = map[string]bool{
	"sql_queries": true, "background_jobs": true, "emails": true,
	"http_requests": true, "errors": true,
}
var summable = map[string]bool{
	"worker_wall_ms": true, "worker_process_cpu_ms": true,
	"worker_thread_cpu_ms": true,
}
var maximum = map[string]bool{
	"queue_wait_ms": true, "scheduled_delay_ms": true,
	"dispatch_wait_ms": true,
}

type policy struct {
	signal            string
	reasonCode        string
	thresholdPercent  *float64
	thresholdAbsolute *float64
	severity          string
	optional          bool
	decision          bool
}

func f64(value float64) *float64 { return &value }

var policies = []policy{
	{signal: "duration_ms", reasonCode: "PERFORMANCE_REGRESSION", thresholdPercent: f64(20), thresholdAbsolute: f64(20), severity: "high", decision: true},
	{signal: "process_cpu_ms", optional: true, decision: false},
	{signal: "thread_cpu_ms", reasonCode: "CPU_TIME_REGRESSION", thresholdPercent: f64(30), thresholdAbsolute: f64(10), severity: "medium", optional: true, decision: true},
	{signal: "queue_wait_ms", reasonCode: "QUEUE_WAIT_REGRESSION", thresholdPercent: f64(20), thresholdAbsolute: f64(20), severity: "medium", optional: true, decision: true},
	{signal: "scheduled_delay_ms", optional: true, decision: false},
	{signal: "dispatch_wait_ms", reasonCode: "DISPATCH_WAIT_REGRESSION", thresholdPercent: f64(20), thresholdAbsolute: f64(20), severity: "medium", optional: true, decision: true},
	{signal: "worker_wall_ms", reasonCode: "WORKER_LATENCY_REGRESSION", thresholdPercent: f64(20), thresholdAbsolute: f64(20), severity: "medium", optional: true, decision: true},
	{signal: "worker_process_cpu_ms", optional: true, decision: false},
	{signal: "worker_thread_cpu_ms", reasonCode: "CPU_TIME_REGRESSION", thresholdPercent: f64(30), thresholdAbsolute: f64(10), severity: "medium", optional: true, decision: true},
	{signal: "sql_queries", reasonCode: "DATABASE_QUERY_REGRESSION", thresholdPercent: f64(25), severity: "high", decision: true},
	{signal: "background_jobs", reasonCode: "SIDE_EFFECT_CHANGED", thresholdAbsolute: f64(0), severity: "medium", decision: true},
	{signal: "emails", reasonCode: "SIDE_EFFECT_CHANGED", thresholdAbsolute: f64(0), severity: "high", decision: true},
	{signal: "http_requests", reasonCode: "NETWORK_BEHAVIOR_CHANGED", thresholdPercent: f64(25), severity: "medium", decision: true},
	{signal: "errors", reasonCode: "NEW_RUNTIME_ERROR", thresholdAbsolute: f64(0), severity: "critical", decision: true},
}

func CompareFiles(
	baselinePath string,
	candidatePath string,
	changedPaths []string,
) (json.RawMessage, error) {
	baseline, err := loadObject(baselinePath)
	if err != nil {
		return nil, fmt.Errorf("baseline capture: %w", err)
	}
	candidate, err := loadObject(candidatePath)
	if err != nil {
		return nil, fmt.Errorf("candidate capture: %w", err)
	}
	pair, err := Pair(baseline, candidate, changedPaths)
	if err != nil {
		return nil, err
	}
	body, err := json.Marshal(pair)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(body), nil
}

func loadObject(path string) (map[string]any, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var value map[string]any
	if err := json.Unmarshal(body, &value); err != nil {
		return nil, err
	}
	if value == nil {
		return nil, errors.New("capture must be a JSON object")
	}
	return value, nil
}

func Pair(
	baselineCapture map[string]any,
	candidateCapture map[string]any,
	changedPaths []string,
) (map[string]any, error) {
	baseline, err := Reduce(baselineCapture)
	if err != nil {
		return nil, fmt.Errorf("reduce baseline: %w", err)
	}
	candidate, err := Reduce(candidateCapture)
	if err != nil {
		return nil, fmt.Errorf("reduce candidate: %w", err)
	}
	runID, ok := stringValue(baseline["run_id"])
	if !ok {
		return nil, errors.New("baseline run_id is required")
	}
	candidateRunID, ok := stringValue(candidate["run_id"])
	if !ok || candidateRunID != runID {
		return nil, errors.New("baseline and candidate must share run_id and scenario_id")
	}
	scenarioID, ok := stringValue(baseline["scenario_id"])
	if !ok {
		return nil, errors.New("baseline scenario_id is required")
	}
	candidateScenarioID, ok := stringValue(candidate["scenario_id"])
	if !ok || candidateScenarioID != scenarioID {
		return nil, errors.New("baseline and candidate must share run_id and scenario_id")
	}
	baseMeasurements, err := objectValue(baseline, "measurements")
	if err != nil {
		return nil, err
	}
	candidateMeasurements, err := objectValue(candidate, "measurements")
	if err != nil {
		return nil, err
	}
	result := BehavioralDiff(baseMeasurements, candidateMeasurements)
	attachTrustedSources(result, baseline, candidate, changedPaths)

	return map[string]any{
		"schema_version": "1",
		"run_id":         runID,
		"scenario_id":    scenarioID,
		"executions": map[string]any{
			"baseline":  baseline,
			"candidate": candidate,
		},
		"result": result,
	}, nil
}

func Reduce(source map[string]any) (map[string]any, error) {
	execution := deepCopyMap(source)
	measurements, err := objectValue(execution, "measurements")
	if err != nil {
		return nil, err
	}
	measurements = deepCopyMap(measurements)
	attributions := normalizeAttributions(execution["attributions"])
	observations := arrayValue(execution["durable_observations"])

	for _, raw := range observations {
		observation, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		signal, ok := stringValue(observation["signal"])
		if !ok {
			continue
		}
		foldMeasurement(measurements, signal, observation)
		appendAttribution(attributions, signal, observation)
	}
	normalizeMeasurements(measurements)
	execution["measurements"] = measurements
	execution["attributions"] = attributions
	execution["runtime_profile"] = map[string]any{
		"request": runtimeDiagnosis(
			measurements["duration_ms"],
			measurements["thread_cpu_ms"],
			true,
		),
		"async": asyncDiagnosis(
			measurements["queue_wait_ms"],
			measurements["worker_wall_ms"],
			true,
		),
		"worker": runtimeDiagnosis(
			measurements["worker_wall_ms"],
			measurements["worker_thread_cpu_ms"],
			true,
		),
	}
	execution["evidence"] = map[string]any{
		"foreground":           true,
		"durable_observations": len(observations),
	}
	return execution, nil
}

func foldMeasurement(
	measurements map[string]any,
	signal string,
	observation map[string]any,
) {
	if countable[signal] {
		measurements[signal] = numericOrZero(measurements[signal]) + 1
		return
	}
	value, ok := observationRuntimeValue(observation)
	if !ok {
		return
	}
	if summable[signal] {
		measurements[signal] = numericOrZero(measurements[signal]) + value
		return
	}
	if maximum[signal] {
		current, exists := numeric(measurements[signal])
		if !exists || value > current {
			measurements[signal] = value
		}
	}
}

func observationRuntimeValue(observation map[string]any) (float64, bool) {
	payload, ok := observation["payload"].(map[string]any)
	if !ok {
		return 0, false
	}
	return numeric(payload["value"])
}

func normalizeMeasurements(measurements map[string]any) {
	for signal, value := range measurements {
		number, ok := numeric(value)
		if !ok {
			continue
		}
		if countable[signal] && math.Trunc(number) == number {
			measurements[signal] = number
		} else if summable[signal] || maximum[signal] {
			measurements[signal] = round1(number)
		}
	}
}

func normalizeAttributions(raw any) map[string]any {
	result := map[string]any{}
	source, ok := raw.(map[string]any)
	if !ok {
		return result
	}
	for signal, locations := range source {
		items := arrayValue(locations)
		copied := make([]any, 0, len(items))
		for _, item := range items {
			if location, ok := item.(map[string]any); ok {
				copied = append(copied, deepCopyMap(location))
			}
		}
		result[signal] = copied
	}
	return result
}

func appendAttribution(
	attributions map[string]any,
	signal string,
	observation map[string]any,
) {
	path, pathOK := stringValue(observation["path"])
	start, startOK := numeric(observation["start_line"])
	end, endOK := numeric(observation["end_line"])
	if !pathOK || !startOK || !endOK {
		return
	}
	confidence, ok := stringValue(observation["confidence"])
	if !ok {
		confidence = "runtime"
	}
	location := map[string]any{
		"path":       path,
		"start_line": start,
		"end_line":   end,
		"confidence": confidence,
	}
	existing := arrayValue(attributions[signal])
	for _, raw := range existing {
		if sameJSONValue(raw, location) {
			return
		}
	}
	attributions[signal] = append(existing, location)
}

func BehavioralDiff(
	baseline map[string]any,
	candidate map[string]any,
) map[string]any {
	signals := map[string]any{}
	findings := make([]any, 0)
	splitQueue := hasNumeric(baseline, "dispatch_wait_ms") &&
		hasNumeric(candidate, "dispatch_wait_ms")

	for _, p := range policies {
		_, basePresent := baseline[p.signal]
		_, candidatePresent := candidate[p.signal]
		if p.optional && !(basePresent && candidatePresent) {
			signals[p.signal] = unavailableSignal(
				baseline,
				candidate,
				p,
			)
			continue
		}

		base := numericOrZero(baseline[p.signal])
		cand := numericOrZero(candidate[p.signal])
		delta := cand - base
		percent := percentChange(base, cand)
		decisionRelevant := p.decision
		if p.signal == "queue_wait_ms" && splitQueue {
			decisionRelevant = false
		}
		regression := decisionRelevant && isRegression(base, cand, p)
		signal := map[string]any{
			"baseline":          base,
			"candidate":         cand,
			"delta":             delta,
			"delta_percent":     percent,
			"display_delta":     displayDelta(delta, percent),
			"available":         true,
			"decision_relevant": decisionRelevant,
			"regression":        regression,
		}
		signals[p.signal] = signal
		if regression {
			findings = append(findings, map[string]any{
				"type":          "behavioral_regression",
				"reason_code":   p.reasonCode,
				"severity":      p.severity,
				"signal":        p.signal,
				"baseline":      base,
				"candidate":     cand,
				"delta":         delta,
				"delta_percent": percent,
			})
		}
	}

	decision := "no_regression"
	recommendation := "allow"
	if len(findings) > 0 {
		decision = "regression"
		recommendation = "review"
		if blockMerge(findings) {
			recommendation = "block"
		}
	}

	return map[string]any{
		"schema_version":       "1",
		"status":               "completed",
		"decision":             decision,
		"merge_recommendation": recommendation,
		"signals":              signals,
		"runtime_diagnosis":    behavioralRuntimeDiagnosis(signals),
		"findings":             findings,
		"recommended_action":   recommendedAction(findings),
	}
}

func unavailableSignal(
	baseline map[string]any,
	candidate map[string]any,
	p policy,
) map[string]any {
	var base any
	if value, ok := baseline[p.signal]; ok {
		base = numericOrZero(value)
	}
	var cand any
	if value, ok := candidate[p.signal]; ok {
		cand = numericOrZero(value)
	}
	return map[string]any{
		"baseline":          base,
		"candidate":         cand,
		"delta":             nil,
		"delta_percent":     nil,
		"display_delta":     "n/a",
		"available":         false,
		"decision_relevant": p.decision,
		"regression":        false,
	}
}

func isRegression(base, candidate float64, p policy) bool {
	if candidate <= base {
		return false
	}
	delta := candidate - base
	if p.thresholdAbsolute != nil && !(delta > *p.thresholdAbsolute) {
		return false
	}
	if p.thresholdPercent != nil &&
		!(percentChange(base, candidate) > *p.thresholdPercent) {
		return false
	}
	return true
}

func percentChange(base, candidate float64) float64 {
	if base == 0 && candidate == 0 {
		return 0
	}
	if base == 0 && candidate > 0 {
		return 100
	}
	return round1(((candidate - base) / base) * 100)
}

func displayDelta(delta, percent float64) string {
	if delta == 0 {
		return "unchanged"
	}
	sign := ""
	if delta > 0 {
		sign = "+"
	}
	return fmt.Sprintf("%s%.1f%%", sign, percent)
}

func runtimeDiagnosis(wallRaw, cpuRaw any, full bool) map[string]any {
	wall, wallOK := numeric(wallRaw)
	cpu, cpuOK := numeric(cpuRaw)
	if !wallOK || !cpuOK || wall <= 0 {
		return map[string]any{
			"classification":    "unknown",
			"cpu_ratio_percent": nil,
		}
	}
	ratio := round1((cpu / wall) * 100)
	classification := "mixed"
	if wall < 10 {
		classification = "insufficient_signal"
	} else if ratio >= 70 {
		classification = "cpu_bound"
	} else if ratio <= 30 {
		classification = "wait_bound"
	}
	result := map[string]any{
		"classification":    classification,
		"cpu_ratio_percent": ratio,
	}
	if full {
		result["wall_ms"] = round1(wall)
		result["thread_cpu_ms"] = round1(cpu)
	}
	return result
}

func asyncDiagnosis(queueRaw, workerRaw any, full bool) map[string]any {
	queue, queueOK := numeric(queueRaw)
	worker, workerOK := numeric(workerRaw)
	if !queueOK || !workerOK {
		return map[string]any{
			"classification":      "unknown",
			"queue_share_percent": nil,
		}
	}
	total := queue + worker
	var share any
	if total > 0 {
		share = round1((queue / total) * 100)
	}
	classification := "insufficient_signal"
	if total >= 10 {
		n := 0.0
		if share != nil {
			n = share.(float64)
		}
		if n >= 70 {
			classification = "queue_bound"
		} else if n <= 30 {
			classification = "worker_bound"
		} else {
			classification = "mixed_async"
		}
	}
	result := map[string]any{
		"classification":      classification,
		"queue_share_percent": share,
	}
	if full {
		result["queue_wait_ms"] = round1(queue)
		result["worker_wall_ms"] = round1(worker)
		result["async_total_ms"] = round1(total)
	}
	return result
}

func behavioralRuntimeDiagnosis(signals map[string]any) map[string]any {
	duration := signalMap(signals, "duration_ms")
	threadCPU := signalMap(signals, "thread_cpu_ms")
	queueWait := signalMap(signals, "queue_wait_ms")
	scheduledDelay := signalMap(signals, "scheduled_delay_ms")
	dispatchWait := signalMap(signals, "dispatch_wait_ms")
	workerWall := signalMap(signals, "worker_wall_ms")
	workerCPU := signalMap(signals, "worker_thread_cpu_ms")

	return map[string]any{
		"request": map[string]any{
			"baseline": runtimeSignalProfile(duration, threadCPU, "baseline"),
			"candidate": runtimeSignalProfile(duration, threadCPU, "candidate"),
		},
		"async": map[string]any{
			"baseline": asyncSignalProfile(queueWait, workerWall, "baseline"),
			"candidate": asyncSignalProfile(queueWait, workerWall, "candidate"),
		},
		"async_delta": asyncDeltaDiagnosis(
			queueWait,
			scheduledDelay,
			dispatchWait,
			workerWall,
		),
		"worker": map[string]any{
			"baseline": runtimeSignalProfile(workerWall, workerCPU, "baseline"),
			"candidate": runtimeSignalProfile(workerWall, workerCPU, "candidate"),
		},
	}
}

func runtimeSignalProfile(
	wall map[string]any,
	cpu map[string]any,
	side string,
) map[string]any {
	if !available(wall) || !available(cpu) {
		return runtimeDiagnosis(nil, nil, false)
	}
	return runtimeDiagnosis(wall[side], cpu[side], false)
}

func asyncSignalProfile(
	queue map[string]any,
	worker map[string]any,
	side string,
) map[string]any {
	if !available(queue) || !available(worker) {
		return asyncDiagnosis(nil, nil, false)
	}
	return asyncDiagnosis(queue[side], worker[side], false)
}

func asyncDeltaDiagnosis(
	queue map[string]any,
	scheduled map[string]any,
	dispatch map[string]any,
	worker map[string]any,
) map[string]any {
	if available(scheduled) && available(dispatch) {
		return splitAsyncDelta(queue, scheduled, dispatch, worker)
	}
	return legacyAsyncDelta(queue, worker)
}

func splitAsyncDelta(
	queue, scheduled, dispatch, worker map[string]any,
) map[string]any {
	scheduledDelta, sOK := numeric(scheduled["delta"])
	dispatchDelta, dOK := numeric(dispatch["delta"])
	workerDelta, wOK := numeric(worker["delta"])
	if !sOK || !dOK || !wOK {
		return unknownAsyncDelta()
	}
	ps := math.Max(scheduledDelta, 0)
	pd := math.Max(dispatchDelta, 0)
	pw := math.Max(workerDelta, 0)
	total := ps + pd + pw
	ss := share(ps, total)
	ds := share(pd, total)
	ws := share(pw, total)

	classification := "no_async_regression"
	dispatchRegression, _ := dispatch["regression"].(bool)
	workerRegression, _ := worker["regression"].(bool)
	switch {
	case dispatchRegression && workerRegression && ds >= 70:
		classification = "dispatch_wait_regression"
	case dispatchRegression && workerRegression && ws >= 70:
		classification = "worker_runtime_regression"
	case dispatchRegression && workerRegression:
		classification = "mixed_async_regression"
	case dispatchRegression:
		classification = "dispatch_wait_regression"
	case workerRegression:
		classification = "worker_runtime_regression"
	case scheduledDelta > 0:
		classification = "scheduled_delay_change"
	}

	var queueDelta any
	if available(queue) {
		if value, ok := numeric(queue["delta"]); ok {
			queueDelta = round1(value)
		}
	} else {
		queueDelta = round1(scheduledDelta + dispatchDelta)
	}
	var enqueueShare any
	var dominant any
	if total > 0 {
		enqueueShare = round1(ss + ds)
		dominant = round1(math.Max(ss, math.Max(ds, ws)))
	}
	return map[string]any{
		"classification":                        classification,
		"queue_wait_delta_ms":                   queueDelta,
		"scheduled_delay_delta_ms":              round1(scheduledDelta),
		"dispatch_wait_delta_ms":                round1(dispatchDelta),
		"worker_wall_delta_ms":                  round1(workerDelta),
		"positive_async_delta_ms":               round1(total),
		"scheduled_delay_delta_share_percent":   ss,
		"dispatch_wait_delta_share_percent":     ds,
		"worker_runtime_delta_share_percent":    ws,
		"enqueue_to_start_delta_share_percent":  enqueueShare,
		"dominant_delta_share_percent":          dominant,
	}
}

func legacyAsyncDelta(queue, worker map[string]any) map[string]any {
	if !available(queue) || !available(worker) {
		return unknownAsyncDelta()
	}
	queueDelta, qOK := numeric(queue["delta"])
	workerDelta, wOK := numeric(worker["delta"])
	if !qOK || !wOK {
		return unknownAsyncDelta()
	}
	queueRegression, _ := queue["regression"].(bool)
	workerRegression, _ := worker["regression"].(bool)
	positiveQueue := math.Max(queueDelta, 0)
	positiveWorker := math.Max(workerDelta, 0)
	total := positiveQueue + positiveWorker
	if !queueRegression && !workerRegression {
		return map[string]any{
			"classification":                       "no_async_regression",
			"queue_wait_delta_ms":                  round1(queueDelta),
			"worker_wall_delta_ms":                 round1(workerDelta),
			"positive_async_delta_ms":              round1(total),
			"enqueue_to_start_delta_share_percent": nil,
			"dominant_delta_share_percent":         nil,
		}
	}
	if total == 0 {
		return unknownAsyncDelta()
	}
	queueShare := round1((positiveQueue / total) * 100)
	classification := "mixed_async_regression"
	if queueShare >= 70 {
		classification = "enqueue_to_start_regression"
	} else if queueShare <= 30 {
		classification = "worker_runtime_regression"
	}
	return map[string]any{
		"classification":                       classification,
		"queue_wait_delta_ms":                  round1(queueDelta),
		"worker_wall_delta_ms":                 round1(workerDelta),
		"positive_async_delta_ms":              round1(total),
		"enqueue_to_start_delta_share_percent": queueShare,
		"dominant_delta_share_percent":         round1(math.Max(queueShare, 100-queueShare)),
	}
}

func unknownAsyncDelta() map[string]any {
	return map[string]any{
		"classification":                       "unknown",
		"queue_wait_delta_ms":                  nil,
		"worker_wall_delta_ms":                 nil,
		"positive_async_delta_ms":              nil,
		"enqueue_to_start_delta_share_percent": nil,
		"dominant_delta_share_percent":         nil,
	}
}

func share(value, total float64) float64 {
	if total == 0 {
		return 0
	}
	return round1((value / total) * 100)
}

func attachTrustedSources(
	result map[string]any,
	baseline map[string]any,
	candidate map[string]any,
	changedPaths []string,
) {
	changed := map[string]bool{}
	for _, path := range changedPaths {
		changed[path] = true
	}
	baseAttr := attributionMap(baseline["attributions"])
	candidateAttr := attributionMap(candidate["attributions"])
	findings := arrayValue(result["findings"])
	for _, raw := range findings {
		finding, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		signal, _ := stringValue(finding["signal"])
		source := trustedSource(
			arrayValue(candidateAttr[signal]),
			arrayValue(baseAttr[signal]),
			changed,
		)
		if source != nil {
			finding["source"] = source
		}
	}
}

func trustedSource(
	locations []any,
	baselineLocations []any,
	changed map[string]bool,
) map[string]any {
	for _, raw := range locations {
		location, ok := raw.(map[string]any)
		if ok && locationConfidence(location) == "explicit" &&
			changed[locationPath(location)] {
			return location
		}
	}
	runtime := changedRuntimeLocations(locations, changed)
	if len(runtime) == 1 {
		return runtime[0]
	}
	baseRuntime := make([]map[string]any, 0)
	for _, raw := range baselineLocations {
		if location, ok := raw.(map[string]any); ok &&
			locationConfidence(location) == "runtime" {
			baseRuntime = append(baseRuntime, location)
		}
	}
	candidateOnly := make([]map[string]any, 0)
	for _, location := range runtime {
		found := false
		for _, base := range baseRuntime {
			if sameSource(location, base) {
				found = true
				break
			}
		}
		if !found {
			candidateOnly = append(candidateOnly, location)
		}
	}
	if len(candidateOnly) == 1 {
		return candidateOnly[0]
	}
	return nil
}

func changedRuntimeLocations(
	locations []any,
	changed map[string]bool,
) []map[string]any {
	result := make([]map[string]any, 0)
	for _, raw := range locations {
		location, ok := raw.(map[string]any)
		if ok && locationConfidence(location) == "runtime" &&
			changed[locationPath(location)] {
			result = append(result, location)
		}
	}
	return result
}

func sameSource(left, right map[string]any) bool {
	for _, key := range []string{"path", "start_line", "end_line", "confidence"} {
		if !sameJSONValue(left[key], right[key]) {
			return false
		}
	}
	return true
}

func blockMerge(findings []any) bool {
	for _, raw := range findings {
		finding, _ := raw.(map[string]any)
		severity, _ := stringValue(finding["severity"])
		if severity == "critical" || severity == "high" {
			return true
		}
	}
	return false
}

func recommendedAction(findings []any) map[string]any {
	if len(findings) == 0 {
		return map[string]any{"type": "none"}
	}
	order := map[string]int{"critical": 0, "high": 1, "medium": 2, "low": 3}
	var primary map[string]any
	best := 99
	for _, raw := range findings {
		finding, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		severity, _ := stringValue(finding["severity"])
		rank, ok := order[severity]
		if !ok {
			rank = 99
		}
		if primary == nil || rank < best {
			primary = finding
			best = rank
		}
	}
	if primary == nil {
		return map[string]any{"type": "none"}
	}
	return map[string]any{
		"type":        "investigate",
		"reason_code": primary["reason_code"],
		"signal":      primary["signal"],
	}
}

func signalMap(signals map[string]any, key string) map[string]any {
	value, _ := signals[key].(map[string]any)
	return value
}

func available(signal map[string]any) bool {
	if signal == nil {
		return false
	}
	value, exists := signal["available"]
	if !exists {
		return true
	}
	available, ok := value.(bool)
	return ok && available
}

func hasNumeric(source map[string]any, key string) bool {
	_, exists := source[key]
	return exists
}

func attributionMap(raw any) map[string]any {
	value, _ := raw.(map[string]any)
	if value == nil {
		return map[string]any{}
	}
	return value
}

func objectValue(source map[string]any, key string) (map[string]any, error) {
	value, ok := source[key].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s must be an object", key)
	}
	return value, nil
}

func arrayValue(raw any) []any {
	value, _ := raw.([]any)
	if value == nil {
		return []any{}
	}
	return value
}

func numeric(raw any) (float64, bool) {
	switch value := raw.(type) {
	case float64:
		return value, true
	case float32:
		return float64(value), true
	case int:
		return float64(value), true
	case int64:
		return float64(value), true
	case json.Number:
		number, err := value.Float64()
		return number, err == nil
	case string:
		number, err := strconv.ParseFloat(value, 64)
		return number, err == nil
	default:
		return 0, false
	}
}

func numericOrZero(raw any) float64 {
	value, ok := numeric(raw)
	if !ok {
		return 0
	}
	return value
}

func stringValue(raw any) (string, bool) {
	value, ok := raw.(string)
	return value, ok
}

func locationPath(location map[string]any) string {
	value, _ := stringValue(location["path"])
	return value
}

func locationConfidence(location map[string]any) string {
	value, _ := stringValue(location["confidence"])
	return value
}

func round1(value float64) float64 {
	return math.Round(value*10) / 10
}

func deepCopyMap(source map[string]any) map[string]any {
	body, _ := json.Marshal(source)
	var result map[string]any
	_ = json.Unmarshal(body, &result)
	return result
}

func sameJSONValue(left, right any) bool {
	l, _ := json.Marshal(left)
	r, _ := json.Marshal(right)
	return string(l) == string(r)
}
