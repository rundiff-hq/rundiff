#!/usr/bin/env python3
import datetime
import glob
import json
import os
import subprocess
import sys

stage = sys.argv[1]
role = sys.argv[2]
detailed = sys.argv[3] == "1"


def read_meminfo():
    values = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as handle:
        for line in handle:
            key, raw = line.split(":", 1)
            fields = raw.strip().split()
            if fields:
                values[key] = int(fields[0]) * 1024
    return values


def process_rss_sum():
    total = 0
    for path in glob.glob("/proc/[0-9]*/status"):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("VmRSS:"):
                        total += int(line.split()[1]) * 1024
                        break
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    return total


def cgroup_current():
    path = "/sys/fs/cgroup/memory.current"
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return int(handle.read().strip())
    except (FileNotFoundError, PermissionError, ValueError):
        return None


def du_bytes(path, use_sudo=False):
    if not use_sudo and not os.path.exists(path):
        return None
    command = ["du", "-sb", path]
    if use_sudo:
        command = ["sudo"] + command
    try:
        output = subprocess.check_output(
            command,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
        )
        return int(output.split()[0])
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
        return None


def docker_command(*args):
    direct = subprocess.run(
        ["docker", "info"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0
    prefix = ["docker"] if direct else ["sudo", "docker"]
    return prefix + list(args)


def docker_output(*args):
    try:
        return subprocess.check_output(
            docker_command(*args),
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def docker_inspect():
    raw = docker_output("inspect", "--size", "rundiff-postgres")
    if not raw:
        return None, None, None
    try:
        item = json.loads(raw)[0]
    except (json.JSONDecodeError, IndexError):
        return None, None, None

    volume_bytes = None
    for mount in item.get("Mounts", []):
        if mount.get("Destination") == "/var/lib/postgresql/data":
            source = mount.get("Source")
            if source:
                volume_bytes = du_bytes(source, use_sudo=True)
            break
    return item.get("SizeRw"), item.get("SizeRootFs"), volume_bytes


meminfo = read_meminfo()
stat = os.statvfs("/")
root_total = stat.f_blocks * stat.f_frsize
root_free = stat.f_bfree * stat.f_frsize
size_rw, size_rootfs, volume_bytes = docker_inspect()

docker_root_bytes = None
if detailed:
    docker_root = docker_output("info", "--format", "{{.DockerRootDir}}")
    if docker_root:
        docker_root_bytes = du_bytes(docker_root, use_sudo=True)

snapshot = {
    "CollectedAtUTC": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat(),
    "Stage": stage,
    "Role": role,
    "Machine": "",
    "GuestMemTotalBytes": meminfo.get("MemTotal", 0),
    "GuestMemAvailableBytes": meminfo.get("MemAvailable", 0),
    "GuestMemUsedProxyBytes": (
        meminfo.get("MemTotal", 0) - meminfo.get("MemAvailable", 0)
    ),
    "ProcessRSSSumBytes": process_rss_sum(),
    "CgroupMemoryCurrentBytes": cgroup_current(),
    "RootFSUsedBytes": root_total - root_free,
    "RepoBytes": du_bytes("/tmp/rundiff-subject") or 0,
    "NodeModulesBytes": du_bytes(
        "/tmp/rundiff-subject/node_modules"
    ) or 0,
    "DockerRootBytes": docker_root_bytes,
    "PostgresSizeRWBytes": size_rw,
    "PostgresSizeRootFSBytes": size_rootfs,
    "PostgresVolumeBytes": volume_bytes,
}
print(json.dumps(snapshot, separators=(",", ":")))
