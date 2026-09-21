#!/usr/bin/env python3
import argparse
import csv
import json
import math
import os
from pathlib import Path
import selectors
import signal
import statistics
import subprocess
import time


READY = "RUNDIFF_SUPERVISOR_READY"
ROOT = Path(__file__).resolve().parents[3]


def percentile(values, q):
    values = sorted(values)
    if not values:
        return None
    index = max(math.ceil(len(values) * q) - 1, 0)
    return values[index]


def read_status(pid):
    result = {}
    path = Path(f"/proc/{pid}/status")
    if not path.exists():
        return result
    for line in path.read_text().splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        value = value.strip()
        if value.endswith(" kB"):
            try:
                result[key] = int(value[:-3].strip())
            except ValueError:
                pass
        elif key == "Threads":
            try:
                result[key] = int(value)
            except ValueError:
                pass
    return result


def read_pss_kb(pid):
    path = Path(f"/proc/{pid}/smaps_rollup")
    if not path.exists():
        return None
    for line in path.read_text().splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return None


def process_table():
    table = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            text = (entry / "stat").read_text()
            end = text.rfind(")")
            fields = text[end + 2 :].split()
            ppid = int(fields[1])
            utime = int(fields[11])
            stime = int(fields[12])
            table[int(entry.name)] = (ppid, utime, stime)
        except (OSError, ValueError, IndexError):
            continue
    return table


def process_tree_pids(root_pid):
    table = process_table()
    children = {}
    for pid, (ppid, _, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    result = []
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        if pid in result:
            continue
        result.append(pid)
        stack.extend(children.get(pid, []))
    return [pid for pid in result if pid in table]


def sample_tree(root_pid):
    ticks = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    table = process_table()
    pids = process_tree_pids(root_pid)
    rss_kb = 0
    hwm_kb = 0
    pss_kb = 0
    pss_available = True
    cpu_ticks = 0
    threads = 0
    fds = 0

    for pid in pids:
        status = read_status(pid)
        rss_kb += status.get("VmRSS", 0)
        hwm_kb += status.get("VmHWM", 0)
        threads += status.get("Threads", 0)
        try:
            fds += len(list(Path(f"/proc/{pid}/fd").iterdir()))
        except OSError:
            pass
        pss = read_pss_kb(pid)
        if pss is None:
            pss_available = False
        else:
            pss_kb += pss
        if pid in table:
            cpu_ticks += table[pid][1] + table[pid][2]

    return {
        "processes": len(pids),
        "rss_kb": rss_kb,
        "hwm_kb": hwm_kb,
        "pss_kb": pss_kb if pss_available else None,
        "cpu_ms": round(cpu_ticks * 1000.0 / ticks, 3),
        "threads": threads,
        "fds": fds,
    }


def implementation_spec(name, go_bin):
    if name == "ruby":
        env = os.environ.copy()
        env["RUNDIFF_SUPERVISOR_BENCHMARK"] = "1"
        env["RUNDIFF_SUPERVISOR_BENCHMARK_HOLD_SECONDS"] = "120"
        return {
            "command": ["bundle", "exec", "ruby", "script/run_cloudflare_executor_bridge.rb"],
            "env": env,
        }
    if name == "go":
        return {
            "command": [go_bin, "supervisor-benchmark-idle", "--hold", "120s"],
            "env": os.environ.copy(),
        }
    raise ValueError(name)


def spawn_ready(name, go_bin, timeout_seconds=30):
    spec = implementation_spec(name, go_bin)
    started = time.perf_counter_ns()
    process = subprocess.Popen(
        spec["command"],
        cwd=ROOT,
        env=spec["env"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
        bufsize=1,
    )

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    events = selector.select(timeout_seconds)
    if not events:
        terminate(process)
        stderr = process.stderr.read()
        raise RuntimeError(f"{name} did not report ready within {timeout_seconds}s: {stderr}")

    line = process.stdout.readline().strip()
    ready_ns = time.perf_counter_ns()
    if line != READY:
        terminate(process)
        stderr = process.stderr.read()
        raise RuntimeError(f"{name} unexpected ready line {line!r}: {stderr}")

    metrics = sample_tree(process.pid)
    metrics.update(
        {
            "implementation": name,
            "startup_ms": round((ready_ns - started) / 1_000_000.0, 3),
        }
    )
    return process, metrics


def terminate(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def run_sequential(pairs, go_bin):
    rows = []
    for pair in range(1, pairs + 1):
        order = ["ruby", "go"] if pair % 2 else ["go", "ruby"]
        for implementation in order:
            process, metrics = spawn_ready(implementation, go_bin)
            try:
                metrics["pair"] = pair
                rows.append(metrics)
                print(
                    f"pair={pair} implementation={implementation} "
                    f"startup_ms={metrics['startup_ms']:.3f} "
                    f"rss_kb={metrics['rss_kb']} "
                    f"pss_kb={metrics['pss_kb']} "
                    f"cpu_ms={metrics['cpu_ms']:.3f}"
                )
            finally:
                terminate(process)
    return rows


def run_concurrency(cohorts, go_bin):
    rows = []
    for count in cohorts:
        for implementation in ("ruby", "go"):
            processes = []
            metrics = []
            try:
                for _ in range(count):
                    process, sample = spawn_ready(implementation, go_bin)
                    processes.append(process)
                    metrics.append(sample)

                aggregate = {
                    "implementation": implementation,
                    "concurrency": count,
                    "rss_kb": sum(item["rss_kb"] for item in metrics),
                    "pss_kb": (
                        sum(item["pss_kb"] for item in metrics)
                        if all(item["pss_kb"] is not None for item in metrics)
                        else None
                    ),
                    "threads": sum(item["threads"] for item in metrics),
                    "fds": sum(item["fds"] for item in metrics),
                    "processes": sum(item["processes"] for item in metrics),
                }
                aggregate["avg_rss_kb"] = round(aggregate["rss_kb"] / count, 3)
                aggregate["avg_pss_kb"] = (
                    round(aggregate["pss_kb"] / count, 3)
                    if aggregate["pss_kb"] is not None
                    else None
                )
                rows.append(aggregate)
                print(
                    f"concurrency={count} implementation={implementation} "
                    f"aggregate_rss_kb={aggregate['rss_kb']} "
                    f"aggregate_pss_kb={aggregate['pss_kb']} "
                    f"avg_pss_kb={aggregate['avg_pss_kb']}"
                )
            finally:
                for process in processes:
                    terminate(process)
    return rows


def summarize_samples(rows):
    result = {}
    metrics = ("startup_ms", "rss_kb", "pss_kb", "cpu_ms", "threads", "fds")
    for implementation in ("ruby", "go"):
        selected = [row for row in rows if row["implementation"] == implementation]
        implementation_summary = {}
        for metric in metrics:
            values = [row[metric] for row in selected if row[metric] is not None]
            implementation_summary[metric] = {
                "count": len(values),
                "median": round(statistics.median(values), 3),
                "p95": round(percentile(values, 0.95), 3),
                "min": round(min(values), 3),
                "max": round(max(values), 3),
            }
        result[implementation] = implementation_summary

    comparisons = {}
    for metric in metrics:
        ruby = result["ruby"][metric]["median"]
        go = result["go"][metric]["median"]
        comparisons[metric] = {
            "ruby_over_go": round(ruby / go, 3) if go else None,
            "absolute_delta": round(ruby - go, 3),
            "reduction_pct": round((ruby - go) / ruby * 100.0, 2) if ruby else None,
        }
    return result, comparisons


def derive_scale(summary, concurrency_rows):
    ruby = summary["ruby"]
    go = summary["go"]
    count = 10_000

    highest = max(row["concurrency"] for row in concurrency_rows)
    cohort = {
        row["implementation"]: row
        for row in concurrency_rows
        if row["concurrency"] == highest
    }

    result = {
        "execution_count": count,
        "startup": {},
        "memory_model": {
            "source_concurrency": highest,
            "note": "Linear PSS projection from the largest measured idle cohort; not a 10,000-concurrent proof.",
        },
    }
    for implementation in ("ruby", "go"):
        startup_ms = summary[implementation]["startup_ms"]["median"]
        cpu_ms = summary[implementation]["cpu_ms"]["median"]
        result["startup"][implementation] = {
            "aggregate_startup_wall_seconds": round(startup_ms * count / 1000.0, 3),
            "aggregate_startup_cpu_seconds": round(cpu_ms * count / 1000.0, 3),
        }
        avg_pss_kb = cohort[implementation]["avg_pss_kb"]
        if avg_pss_kb is not None:
            result["memory_model"][implementation] = {
                "avg_pss_kb_at_measured_concurrency": avg_pss_kb,
                "projected_10000_pss_gib": round(avg_pss_kb * count / 1024.0 / 1024.0, 3),
            }

    result["startup"]["saved_wall_seconds"] = round(
        result["startup"]["ruby"]["aggregate_startup_wall_seconds"]
        - result["startup"]["go"]["aggregate_startup_wall_seconds"],
        3,
    )
    result["startup"]["saved_cpu_seconds"] = round(
        result["startup"]["ruby"]["aggregate_startup_cpu_seconds"]
        - result["startup"]["go"]["aggregate_startup_cpu_seconds"],
        3,
    )
    if "ruby" in result["memory_model"] and "go" in result["memory_model"]:
        result["memory_model"]["projected_saved_gib"] = round(
            result["memory_model"]["ruby"]["projected_10000_pss_gib"]
            - result["memory_model"]["go"]["projected_10000_pss_gib"],
            3,
        )
    return result


def write_outputs(output_root, samples, concurrency, summary, comparisons, scale):
    output_root.mkdir(parents=True, exist_ok=True)

    sample_fields = [
        "pair",
        "implementation",
        "startup_ms",
        "rss_kb",
        "hwm_kb",
        "pss_kb",
        "cpu_ms",
        "threads",
        "fds",
        "processes",
    ]
    with (output_root / "samples.tsv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=sample_fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(samples)

    concurrency_fields = [
        "implementation",
        "concurrency",
        "rss_kb",
        "pss_kb",
        "avg_rss_kb",
        "avg_pss_kb",
        "threads",
        "fds",
        "processes",
    ]
    with (output_root / "concurrency.tsv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=concurrency_fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(concurrency)

    payload = {
        "summary": summary,
        "comparisons": comparisons,
        "scale_10000": scale,
    }
    (output_root / "summary.json").write_text(json.dumps(payload, indent=2) + "\n")

    lines = [
        "# RunDiff Ruby vs Go supervisor benchmark",
        "",
        "## Sequential startup / footprint",
        "",
        "| Metric | Ruby median | Go median | Ruby / Go | Reduction |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    labels = {
        "startup_ms": "Startup to ready (ms)",
        "rss_kb": "Idle RSS (KiB)",
        "pss_kb": "Idle PSS (KiB)",
        "cpu_ms": "CPU to ready (ms)",
        "threads": "Threads",
        "fds": "File descriptors",
    }
    for metric, label in labels.items():
        ruby = summary["ruby"][metric]["median"]
        go = summary["go"][metric]["median"]
        comp = comparisons[metric]
        ratio = f"{comp['ruby_over_go']:.3f}x" if comp["ruby_over_go"] is not None else "n/a"
        reduction = f"{comp['reduction_pct']:.2f}%" if comp["reduction_pct"] is not None else "n/a"
        lines.append(f"| {label} | {ruby} | {go} | {ratio} | {reduction} |")

    lines += [
        "",
        "## Idle concurrency",
        "",
        "| Implementation | Processes requested | Aggregate RSS KiB | Aggregate PSS KiB | Avg PSS KiB |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for row in concurrency:
        lines.append(
            f"| {row['implementation']} | {row['concurrency']} | {row['rss_kb']} | "
            f"{row['pss_kb']} | {row['avg_pss_kb']} |"
        )

    lines += [
        "",
        "## 10,000-execution derived model",
        "",
        f"- Aggregate startup wall saved: {scale['startup']['saved_wall_seconds']} s",
        f"- Aggregate startup CPU saved: {scale['startup']['saved_cpu_seconds']} s",
    ]
    if "projected_saved_gib" in scale["memory_model"]:
        lines.append(
            f"- Linear 10,000-idle-process PSS difference: "
            f"{scale['memory_model']['projected_saved_gib']} GiB"
        )
    lines += [
        "",
        "> The 10,000-process memory figure is a linear projection from the largest measured idle cohort, not a 10,000-concurrent execution proof.",
        "",
    ]
    (output_root / "summary.md").write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--concurrency", default="1,5,10")
    parser.add_argument(
        "--go-bin",
        default=os.environ.get("RUNDIFF_GO_EXECUTOR_BIN", "/tmp/rundiff-executor"),
    )
    parser.add_argument(
        "--output-root",
        default=str(ROOT / "tmp/rundiff/supervisor-benchmark"),
    )
    args = parser.parse_args()

    if args.pairs < 1 or args.pairs > 50:
        raise SystemExit("--pairs must be between 1 and 50")
    cohorts = [int(value) for value in args.concurrency.split(",") if value]
    if not cohorts or min(cohorts) < 1 or max(cohorts) > 25:
        raise SystemExit("--concurrency values must be between 1 and 25")

    samples = run_sequential(args.pairs, args.go_bin)
    concurrency = run_concurrency(cohorts, args.go_bin)
    summary, comparisons = summarize_samples(samples)
    scale = derive_scale(summary, concurrency)
    write_outputs(Path(args.output_root), samples, concurrency, summary, comparisons, scale)

    print(json.dumps({"summary": summary, "comparisons": comparisons, "scale_10000": scale}, indent=2))


if __name__ == "__main__":
    main()
