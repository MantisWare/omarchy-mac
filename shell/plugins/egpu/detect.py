"""GPU discovery shared by the miaOS eGPU inventory and placement manager."""

from pathlib import Path
import fcntl
import json
import os
import re
import subprocess
import tempfile
import time

MIB = 1024 * 1024
STATE_DIR = Path(os.environ.get("OMARCHY_EGPU_STATE_DIR", Path.home() / ".local/state/omarchy"))
LLAMA_CACHE = STATE_DIR / "egpu-llama-devices-cache.json"
LLAMA_CACHE_LOCK = STATE_DIR / "egpu-llama-devices-cache.lock"
LLAMA_CACHE_TTL = float(os.environ.get("OMARCHY_EGPU_LLAMA_CACHE_TTL", "60"))


def read(path):
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def positive_drm_allocation(fdinfo):
    fields = dict(line.split(":", 1) for line in fdinfo.splitlines() if ":" in line)
    allocated = 0
    for key, value in fields.items():
        if key.startswith(("drm-memory-", "drm-resident-")):
            match = re.match(r"\s*([0-9]+)\s+KiB", value)
            if match:
                allocated = max(allocated, int(match.group(1)) * 1024)
    return fields.get("drm-pdev", "").strip() if allocated else "", allocated


def process_allocations(pid, proc=Path("/proc")):
    devices = {}
    for fdinfo in (proc / str(pid) / "fdinfo").glob("*"):
        device, allocated = positive_drm_allocation(read(fdinfo))
        if device:
            devices[device] = max(devices.get(device, 0), allocated)
    return devices


def external_gpu_ids(pci=Path("/sys/bus/pci/devices")):
    devices = list(pci.glob("*"))
    roots = []
    for device in devices:
        try:
            driver = (device / "driver").resolve(strict=True).name
        except OSError:
            continue
        if driver == "thunderbolt":
            upstream = device.resolve().parent.parent
            if re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", upstream.name):
                roots.append(upstream)

    result = set()
    for device in devices:
        if not read(device / "class").startswith("0x03"):
            continue
        path = device.resolve()
        if any(root in path.parents for root in roots) or any(
            read(parent / "removable") == "removable" for parent in (path, *path.parents)
        ):
            result.add(device.name)
    return result


def pci_names():
    names = {}
    try:
        result = subprocess.run(
            ["lspci", "-D"], capture_output=True, text=True, timeout=3, check=False
        )
        for line in result.stdout.splitlines():
            address, _, description = line.partition(" ")
            names[address] = description.split(": ", 1)[-1]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return names


def normalize_pci_address(value):
    match = re.fullmatch(
        r"(?:[0-9a-fA-F]{4})?([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])",
        value.strip(),
    )
    return match.group(1).lower() if match else value.strip().lower()


def parse_nvidia_memory(output):
    devices = {}
    for line in output.splitlines():
        fields = [field.strip() for field in line.split(",")]
        if len(fields) != 3:
            continue
        try:
            total = round(float(fields[1]) * MIB)
            used = round(float(fields[2]) * MIB)
        except ValueError:
            continue
        devices[normalize_pci_address(fields[0])] = (total, used)
    return devices


def nvidia_memory():
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=pci.bus_id,memory.total,memory.used",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        return parse_nvidia_memory(result.stdout)
    except (OSError, subprocess.TimeoutExpired):
        return {}


def parse_llama_memory(output):
    devices = []
    for line in output.splitlines():
        match = re.match(
            r"\s*([^:\s]+)\s*:\s*.+\(([0-9]+) MiB,\s*([0-9]+) MiB free\)\s*$",
            line,
        )
        if match:
            total = int(match.group(2)) * MIB
            free = int(match.group(3)) * MIB
            devices.append((match.group(1), total, max(0, total - free)))
    return devices


def gpu_signature(pci=Path("/sys/bus/pci/devices")):
    signature = []
    for device in sorted(pci.glob("*"), key=lambda item: item.name):
        if not read(device / "class").startswith("0x03"):
            continue
        try:
            driver = (device / "driver").resolve(strict=True).name
        except OSError:
            driver = "not-bound"
        signature.append((device.name, read(device / "vendor"), read(device / "device"), driver))
    return signature


def llama_device_output(extra=None):
    """Cache expensive llama.cpp Vulkan discovery across short-lived poll workers."""
    binary = os.environ.get("OMARCHY_EGPU_LLAMA_BIN", "/usr/bin/llama-server")
    environment = os.environ.copy()
    environment.pop("DRI_PRIME", None)
    environment.update(extra or {})
    try:
        binary_mtime = Path(binary).stat().st_mtime_ns
    except OSError:
        binary_mtime = 0
    key = json.dumps(
        {
            "binary": binary,
            "binaryMtime": binary_mtime,
            "driPrime": environment.get("DRI_PRIME", ""),
            "gpus": gpu_signature(),
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LLAMA_CACHE_LOCK.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            cache = json.loads(LLAMA_CACHE.read_text())
        except (OSError, ValueError, TypeError):
            cache = {}
        entry = cache.get(key, {})
        if time.time() - entry.get("updated", 0) < LLAMA_CACHE_TTL:
            return str(entry.get("output", ""))
        try:
            result = subprocess.run(
                [binary, "--list-devices"],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            output = result.stdout + "\n" + result.stderr
        except (OSError, subprocess.TimeoutExpired):
            output = ""
        cache[key] = {"updated": time.time(), "output": output}
        fd, temporary = tempfile.mkstemp(prefix=LLAMA_CACHE.name + ".", dir=STATE_DIR)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(cache, stream)
            os.replace(temporary, LLAMA_CACHE)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
        return output


def vulkan_memory(device_id):
    dri_prime = "pci-" + device_id.replace(":", "_").replace(".", "_") + "!"
    devices = parse_llama_memory(llama_device_output({"DRI_PRIME": dri_prime}))
    return devices[0][1:] if len(devices) == 1 else None


def gpus(pci=Path("/sys/bus/pci/devices")):
    external = external_gpu_ids(pci)
    names = pci_names()
    nvidia = None
    result = []
    for device in sorted(pci.glob("*"), key=lambda item: item.name):
        if not read(device / "class").startswith("0x03"):
            continue
        try:
            driver = (device / "driver").resolve(strict=True).name
        except OSError:
            driver = "not bound"
        total_text = read(device / "mem_info_vram_total")
        used_text = read(device / "mem_info_vram_used")
        total = int(total_text) if total_text.isdigit() else None
        used = int(used_text) if used_text.isdigit() else None
        memory_type = "dedicated" if total is not None else "unknown"
        memory_source = "drm-sysfs" if total is not None else ""
        if total is None and driver == "nvidia":
            if nvidia is None:
                nvidia = nvidia_memory()
            telemetry = nvidia.get(device.name)
            if telemetry:
                total, used = telemetry
                memory_type = "dedicated"
                memory_source = "nvidia-smi"
        if total is None:
            telemetry = vulkan_memory(device.name)
            if telemetry:
                total, used = telemetry
                memory_type = "shared" if driver in {"i915", "xe"} else "dedicated"
                memory_source = "vulkan-budget"
        vendor = read(device / "vendor")
        product = read(device / "device")
        result.append(
            {
                "id": device.name,
                "name": names.get(device.name, read(device / "product_name") or device.name),
                "driver": driver,
                "vendor": vendor,
                "device": product,
                "external": device.name in external,
                "present": True,
                "total": total,
                "used": used,
                "available": max(0, total - (used or 0)) if total is not None else None,
                "memoryType": memory_type,
                "memorySource": memory_source,
                "selectable": driver in {"amdgpu", "radeon", "i915", "xe"},
            }
        )
    return result


def user_processes(proc=Path("/proc")):
    for path in proc.glob("[0-9]*"):
        try:
            if path.stat().st_uid != os.getuid():
                continue
            comm = read(path / "comm")
            args = (path / "cmdline").read_bytes().decode().split("\0")
            yield int(path.name), comm, args
        except (OSError, UnicodeError, ValueError):
            continue
