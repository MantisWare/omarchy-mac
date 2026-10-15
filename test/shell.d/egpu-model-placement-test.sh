#!/bin/bash

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

plugin="$ROOT/shell/plugins/egpu"
manager="$plugin/manager.py"
widget="$plugin/Widget.qml"
migration="$ROOT/migrations/1790805582.sh"
layout_migration="$ROOT/migrations/1790809281.sh"

PYTHONDONTWRITEBYTECODE=1 python3 - "$plugin/detect.py" "$manager" "$plugin/inventory.py" <<'PY'
import ast
from pathlib import Path
import sys
for name in sys.argv[1:]:
    ast.parse(Path(name).read_text(), filename=name)
PY
jq -e '.id == "omarchy.egpu" and .kinds == ["bar-widget"] and .entryPoints.barWidget == "Widget.qml"' \
  "$plugin/manifest.json" >/dev/null || fail "the packaged GPU plugin manifest is valid"
pass "the packaged GPU manager has valid Python and manifest syntax"

cache_tmp=$(mktemp -d)
fake_llama="$cache_tmp/llama-server"
cache_calls="$cache_tmp/calls"
cat >"$fake_llama" <<'SH'
#!/bin/bash
printf '%s\n' "${DRI_PRIME:-default}" >>"$OMARCHY_EGPU_TEST_CALLS"
printf '%s\n' 'Vulkan0: Test GPU (8192 MiB, 6144 MiB free)'
SH
chmod +x "$fake_llama"

run_cached_backend() {
  OMARCHY_EGPU_STATE_DIR="$cache_tmp/state" \
    OMARCHY_EGPU_LLAMA_BIN="$fake_llama" \
    OMARCHY_EGPU_LLAMA_CACHE_TTL=3600 \
    OMARCHY_EGPU_TEST_CALLS="$cache_calls" \
    DRI_PRIME="${1:-}" \
    OMARCHY_EGPU_TEST_TARGET="${2:-}" \
    python3 - "$plugin" <<'PY'
import os
import sys
sys.path.insert(0, sys.argv[1])
import manager
target = os.environ.get('OMARCHY_EGPU_TEST_TARGET')
extra = {'DRI_PRIME': target} if target else None
assert manager.backend_devices(extra) == [('Vulkan0', 'Test GPU (8192 MiB, 6144 MiB free)')]
PY
}

run_cached_backend
run_cached_backend
[[ $(wc -l <"$cache_calls") == 1 ]] || fail "short-lived manager runs share llama device discovery"

python3 - "$fake_llama" <<'PY'
import os
from pathlib import Path
import sys
path = Path(sys.argv[1])
stamp = path.stat().st_mtime_ns + 1
os.utime(path, ns=(stamp, stamp))
PY
run_cached_backend
[[ $(wc -l <"$cache_calls") == 2 ]] || fail "the llama cache invalidates when the binary changes"

run_cached_backend 'pci-ambient-filter!'
[[ $(wc -l <"$cache_calls") == 2 ]] || fail "ambient DRI_PRIME does not filter baseline llama discovery"
[[ $(tail -n 1 "$cache_calls") == "default" ]] || fail "baseline llama discovery clears ambient DRI_PRIME"

run_cached_backend 'pci-ambient-filter!' 'pci-0000_03_00_0!'
[[ $(wc -l <"$cache_calls") == 3 ]] || fail "the llama cache invalidates when DRI_PRIME changes"
[[ $(tail -n 1 "$cache_calls") == "pci-0000_03_00_0!" ]] || fail "targeted llama discovery applies its explicit DRI_PRIME"

OMARCHY_EGPU_STATE_DIR="$cache_tmp/state" \
  OMARCHY_EGPU_LLAMA_BIN="$fake_llama" \
  OMARCHY_EGPU_LLAMA_CACHE_TTL=3600 \
  OMARCHY_EGPU_TEST_CALLS="$cache_calls" \
  python3 - "$plugin" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import detect
detect.gpu_signature = lambda: [('0000:01:00.0', '0x1002', '0x73ff', 'amdgpu')]
detect.llama_device_output()
detect.llama_device_output()
detect.gpu_signature = lambda: [('0000:02:00.0', '0x10de', '0x2684', 'nvidia')]
detect.llama_device_output()
PY
[[ $(wc -l <"$cache_calls") == 5 ]] || fail "the llama cache invalidates when the GPU signature changes"
rm -rf "$cache_tmp"
pass "llama device discovery is cached across manager runs and invalidated by runtime identity"

python3 - "$plugin" <<'PY'
import os
from pathlib import Path
import stat
import sys
import tempfile

state = tempfile.TemporaryDirectory()
os.environ['OMARCHY_EGPU_STATE_DIR'] = state.name
sys.path.insert(0, sys.argv[1])
import detect
import manager

llama_output = '''Available devices:
  Vulkan0: AMD Radeon Graphics (RADV NAVI14) (4080 MiB, 1412 MiB free)
  Vulkan2: Intel(R) UHD Graphics 630 (CFL GT2) (11907 MiB, 8166 MiB free)
'''
assert detect.parse_llama_memory(llama_output) == [
    ('Vulkan0', 4080 * 1024 * 1024, 2668 * 1024 * 1024),
    ('Vulkan2', 11907 * 1024 * 1024, 3741 * 1024 * 1024),
]
assert detect.parse_nvidia_memory('00000000:01:00.0, 8192, 1536\n') == {
    '0000:01:00.0': (8192 * 1024 * 1024, 1536 * 1024 * 1024),
}

device, allocated = detect.positive_drm_allocation('drm-pdev:\t0000:03:00.0\ndrm-memory-vram:\t727072 KiB\n')
assert device == '0000:03:00.0' and allocated == 727072 * 1024
device, allocated = detect.positive_drm_allocation('drm-pdev:\t0000:00:02.0\ndrm-memory-vram:\t0 KiB\n')
assert device == '' and allocated == 0

env = Path(state.name) / '.env'
env.write_text('# keep this\nWHISPER_VULKAN_DEVICE=7\nDRI_PRIME=old\nDRI_PRIME=duplicate\nUNRELATED=yes\n')
env.chmod(0o640)
manager.replace_env(env, {
    'WHISPER_VULKAN_ENABLED': 'true',
    'WHISPER_VULKAN_DEVICE': '0',
    'DRI_PRIME': manager.dri_prime('0000:03:00.0'),
})
text = env.read_text()
assert '# keep this' in text and 'UNRELATED=yes' in text
assert text.count('DRI_PRIME=') == 1
assert 'DRI_PRIME=pci-0000_03_00_0!' in text
assert 'WHISPER_VULKAN_DEVICE=0' in text
assert 'WHISPER_VULKAN_ENABLED=true' in text
assert stat.S_IMODE(env.stat().st_mode) == 0o640
vulkan_binary = Path(state.name) / 'whisper-vulkan'
vulkan_binary.write_bytes(b'ELF...ggml_vulkan...')
cpu_binary = Path(state.name) / 'whisper-cpu'
cpu_binary.write_bytes(b'ELF...ggml_cpu...')
assert manager.binary_has_vulkan(vulkan_binary)
assert not manager.binary_has_vulkan(cpu_binary)

devices = [
    {'id': '0000:03:00.0', 'name': 'Internal Radeon', 'driver': 'amdgpu', 'external': False, 'selectable': True},
    {'id': '0000:0e:00.0', 'name': 'External Radeon', 'driver': 'amdgpu', 'external': True, 'selectable': True},
    {'id': '0000:00:02.0', 'name': 'Internal Intel', 'driver': 'i915', 'external': False, 'selectable': True},
]
models = [
    {'id': 'llama:qwen', 'routerId': 'qwen', 'runtime': 'llama.cpp'},
    {'id': 'llama:mistral', 'routerId': 'mistral', 'runtime': 'llama.cpp'},
]
# Backend names include volatile free-VRAM figures. PCI filtering must still
# resolve the selected Intel device to its stable unfiltered Vulkan index.
manager.backend_devices = lambda extra=None: (
    [('Vulkan0', 'Intel(R) UHD Graphics 630 (CFL GT2) (11907 MiB, 8640 MiB free)')]
    if extra else [
        ('Vulkan0', 'AMD Radeon Graphics (RADV NAVI14) (4080 MiB, 132 MiB free)'),
        ('Vulkan1', 'AMD Radeon RX 6600 XT (RADV NAVI23) (8192 MiB, 5703 MiB free)'),
        ('Vulkan2', 'Intel(R) UHD Graphics 630 (CFL GT2) (11907 MiB, 8634 MiB free)'),
    ]
)
assert manager.backend_for(devices[2]) == 'Vulkan2'
saved = {'models': {
    'llama:qwen': {'preferred': '0000:00:02.0'},
    'llama:mistral': {'preferred': '0000:0e:00.0'},
}}
manager.backend_for = lambda gpu: 'Vulkan-' + gpu['id']
preset = manager.preset_text(models, devices, saved).decode()
assert '[qwen]\ndevice = Vulkan-0000:00:02.0' in preset
assert '[mistral]\ndevice = Vulkan-0000:0e:00.0' in preset
unsaved = manager.preset_text(models, devices, {'models': {}}).decode()
assert '[qwen]\ndevice = Vulkan-0000:0e:00.0' in unsaved
assert '[mistral]\ndevice = Vulkan-0000:0e:00.0' in unsaved
current = manager.preset_text([dict(models[1], current='0000:03:00.0')], devices, {'models': {}}).decode()
assert '[mistral]\ndevice = Vulkan-0000:03:00.0' in current
overridden = manager.preset_text(models, devices, saved, ('llama:qwen', '0000:0e:00.0')).decode()
assert '[qwen]\ndevice = Vulkan-0000:0e:00.0' in overridden

# Match the real llama router envelope and nested status schema.
fixture = Path(state.name) / 'models.json'
model_path = '/models/qwen.gguf'
fixture.write_text('''{"object":"list","data":[{"id":"qwen-live","status":{"value":"loaded","args":["llama-server","--model","/models/qwen.gguf"],"preset":"[qwen-live]"},"meta":{"size":1234}}]}''')
os.environ['OMARCHY_EGPU_LLAMA_MODELS_FIXTURE'] = str(fixture)
rows = manager.router_models()
assert len(rows) == 1 and manager.router_status(rows[0]) == 'loaded'
assert manager.router_path(rows[0]) == model_path
assert manager.router_status({'status': 'loaded'}) == 'loaded'
assert manager.router_path({'args': {'model': '/models/synthetic.gguf'}}) == '/models/synthetic.gguf'
top_level_args = {'status': 'loaded', 'args': ['llama-server', '--model', '/models/top-level.gguf']}
assert manager.router_args(top_level_args) == top_level_args['args']
assert manager.router_path(top_level_args) == '/models/top-level.gguf'
api_calls = []
class ApiResponse:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *args): pass
manager.urllib.request.urlopen = lambda request, timeout=0: api_calls.append((request.method, request.full_url, request.headers.get('Content-type'), request.data)) or ApiResponse()
manager.router_action('model with space', 'load', timeout=1)
assert api_calls == [('POST', 'http://127.0.0.1:8127/models/load', 'application/json', b'{"model": "model with space"}')]
manager.package_installed = lambda name: True
manager.backend_devices = lambda extra=None: [('Vulkan0', 'Radeon')]
manager.process_allocations = lambda pid, proc: {'0000:03:00.0': 1024}
qwen_rows = manager.llama_models([(42, 'llama-server', ['llama-server', '--model', model_path])], devices)
assert len(qwen_rows) == 1 and qwen_rows[0]['loaded']
assert qwen_rows[0]['allowedDevices'] == [device['id'] for device in devices]
assert qwen_rows[0]['path'] == model_path
assert qwen_rows[0]['estimated'] and qwen_rows[0]['required'] == 1234 + 512 * 1024 * 1024

# Vulkan opens DRM nodes on multiple GPUs for small bookkeeping allocations.
# Placement is the GPU holding the dominant model allocation, not the first
# PCI address with any non-zero allocation.
manager.process_allocations = lambda pid, proc: {
    '0000:00:02.0': 588 * 1024 * 1024,
    '0000:03:00.0': 44 * 1024,
    '0000:0e:00.0': 1290 * 1024 * 1024,
}
dominant = manager.llama_models([(42, 'llama-server', ['llama-server', '--model', model_path])], devices)[0]
assert dominant['devices'] == ['0000:0e:00.0']
assert dominant['current'] == '0000:0e:00.0'
manager.process_allocations = lambda pid, proc: {'0000:03:00.0': 1024}

# With no saved state, loaded models keep their observed GPU while models with
# no observed allocation prefer an available eGPU. Names do not affect policy.
manager.gpus = lambda: devices
manager.user_processes = lambda proc: iter([(42, 'llama-server', ['llama-server', '--model', model_path])])
manager.echo_model = lambda processes: None
manager.router_models = lambda: [
    {'id': 'qwen-live', 'status': {'value': 'loaded', 'args': ['llama-server', '--model', model_path]}, 'meta': {'size': 1234}},
    {'id': 'mistral-live', 'status': {'value': 'loaded', 'args': ['llama-server', '--model', '/models/mistral.gguf']}, 'meta': {'size': 1234}},
]
inventory = manager.inventory()
by_id = {model['id']: model for model in inventory['models']}
assert by_id['llama:qwen-live']['preferred'] == '0000:03:00.0'
assert by_id['llama:qwen-live']['allowedDevices'] == [device['id'] for device in devices]
assert by_id['llama:mistral-live']['preferred'] == '0000:0e:00.0'
manager.gpus = lambda: devices[:1]
internal_only = manager.inventory()
assert {model['id']: model for model in internal_only['models']}['llama:mistral-live']['preferred'] == '0000:03:00.0'
manager.gpus = lambda: devices

# Current router status, including an intentional unload, replaces historical
# load state so transitions never resurrect an old loaded set.
manager.user_processes = lambda proc: iter([])
manager.router_models = lambda: [{'id': 'mistral-live', 'status': {'value': 'unloaded', 'args': ['llama-server', '--model', '/models/mistral.gguf']}}]
manager.inventory()
observed = manager.read_json(manager.STATE_FILE, {})['models']['llama:mistral-live']
assert observed['wasLoaded'] is False

# Stock/CPU EchoCraft is visible but not actionable until its pinned Vulkan
# executable is actually present and contains compiled Vulkan support.
manager.echo_model = lambda processes: {'id': 'echocraft-whisper', 'name': 'Whisper', 'runtime': 'EchoCraft / whisper.cpp',
                                        'loaded': False, 'devices': [], 'required': 1, 'executable': str(cpu_binary)}
manager.router_models = lambda: []
speech = {model['id']: model for model in manager.inventory()['models']}['echocraft-whisper']
assert not speech['capable'] and 'not Vulkan-capable' in speech['reason']
assert speech['allowedDevices'] == [device['id'] for device in devices]
manager.echo_model = lambda processes: None

# Unsafe section names are disabled and never serialized.
for unsafe in ('bad]section', 'bad\nsection', 'bad\rsection', 'bad\x01section'):
    assert not manager.valid_router_id(unsafe)
    rejected = manager.preset_text([{'id': 'llama:bad', 'routerId': unsafe, 'runtime': 'llama.cpp'}], devices, {'models': {}}).decode()
    assert unsafe not in rejected
manager.router_models = lambda: [{'id': 'bad]section', 'status': {'value': 'loaded', 'args': ['llama-server', '--model', model_path]}}]
assert 'unsafe' in manager.llama_models([], devices)[0]['reason']

# A first CPU-to-eGPU assignment records the built-in Radeon as its fallback.
manager.STATE_FILE = Path(state.name) / 'placement.json'
manager.LLAMA_PRESET = Path(state.name) / 'llama-models.ini'
manager.JOURNAL_FILE = Path(state.name) / 'transaction.json'
manager.OPERATION_FILE = Path(state.name) / 'operation.json'
transition_model = {'id': 'llama:mistral', 'routerId': 'mistral', 'name': 'mistral', 'runtime': 'llama.cpp',
                    'capable': True, 'current': '', 'devices': [], 'allowedDevices': [d['id'] for d in devices],
                    'fits': {d['id']: {'status': 'fits'} for d in devices}}
real_inventory = manager.inventory
real_wait_for_model = manager.wait_for_model
real_load_router_models = manager.load_router_models
real_preset_text = manager.preset_text
manager.inventory = lambda: {'gpus': devices, 'models': [transition_model], 'operation': {}}
manager.preset_text = lambda *args, **kwargs: b'version = 1\n'
manager.progress = lambda *args: None
manager.restart = lambda service: None
manager.notify = lambda *args, **kwargs: ''
loaded_sets = []
manager.load_router_models = lambda ids: loaded_sets.append(list(ids))
manager.wait_for_model = lambda model, target, timeout=40: True
manager.transition('llama:mistral', '0000:0e:00.0')
stored = manager.read_json(manager.STATE_FILE, {})['models']['llama:mistral']
assert stored['preferred'] == '0000:0e:00.0'
assert stored['fallback'] == '0000:03:00.0'
assert loaded_sets == [['mistral']]

# A crash journal restores configuration and the prior router load set.
manager.LLAMA_PRESET.write_text('changed\n')
manager.save_journal(manager.LLAMA_PRESET, True, b'original\n', manager.LLAMA_SERVICE, ['qwen-live'], '', 'llama:mistral')
manager.recover_journal()
# An empty/unverified prior placement is not considered a successful rollback:
# recovery rewrites the preset for a verified available fallback.
assert manager.LLAMA_PRESET.read_bytes() == b'version = 1\n'
assert loaded_sets[-1] == ['qwen-live'] and not manager.JOURNAL_FILE.exists()
manager.save_journal(manager.LLAMA_PRESET, True, b'original\n', manager.LLAMA_SERVICE, [], '', 'llama:mistral')
pending = manager.read_json(manager.JOURNAL_FILE, {})
pending['lastAttempt'] = __import__('time').time()
manager.write_json(manager.JOURNAL_FILE, pending)
assert manager.recover_journal() is False
manager.JOURNAL_FILE.unlink()

# Inventory observations merge under a separate state lock and cannot overwrite
# placement fields committed after an inventory snapshot was collected.
manager.write_json(manager.STATE_FILE, {'models': {'llama:mistral': {
    'preferred': '0000:0e:00.0', 'fallback': '0000:03:00.0', 'lastGood': '0000:0e:00.0',
}}})
merged = manager.merge_model_observations({'llama:mistral': {
    'runtimeMetadata': {'runtime': 'llama.cpp', 'routerId': 'mistral'}, 'wasLoaded': False,
}})
assert merged['models']['llama:mistral']['preferred'] == '0000:0e:00.0'
assert merged['models']['llama:mistral']['fallback'] == '0000:03:00.0'
assert merged['models']['llama:mistral']['lastGood'] == '0000:0e:00.0'
assert merged['models']['llama:mistral']['wasLoaded'] is False

# Exercise the lock across processes: observation churn may update runtime
# metadata, but can never erase a concurrently committed placement.
import multiprocessing
def observation_writer():
    for index in range(40):
        manager.merge_model_observations({'llama:mistral': {'runtimeMetadata': {'runtime': 'llama.cpp', 'routerId': 'mistral', 'sample': index}}})
def placement_writer():
    for index in range(40):
        manager.update_state(lambda value: value.setdefault('models', {}).setdefault('llama:mistral', {}).update(
            preferred='0000:0e:00.0', fallback='0000:03:00.0', lastGood='0000:0e:00.0', generation=index))
processes = multiprocessing.get_context('fork')
workers = [processes.Process(target=observation_writer), processes.Process(target=placement_writer)]
for worker in workers: worker.start()
for worker in workers: worker.join()
assert all(worker.exitcode == 0 for worker in workers)
raced = manager.read_json(manager.STATE_FILE, {})['models']['llama:mistral']
assert raced['preferred'] == '0000:0e:00.0' and raced['fallback'] == '0000:03:00.0'
assert raced['lastGood'] == '0000:0e:00.0' and raced['generation'] == 39
assert manager.journal_load_ids({'model': 'llama:mistral', 'priorLoaded': [], 'selectedRouterId': 'mistral', 'selectedWasLoaded': True}) == ['mistral']
assert manager.journal_load_ids({'model': 'llama:mistral', 'priorLoaded': ['qwen'], 'selectedRouterId': 'mistral', 'selectedWasLoaded': True}) == ['qwen', 'mistral']
assert manager.journal_load_ids({'model': 'llama:mistral', 'priorLoaded': ['qwen'], 'selectedRouterId': 'mistral', 'selectedWasLoaded': False}) == ['qwen']

# A GPU recovery journal remains until prior DRM placement is verified.
manager.save_journal(manager.LLAMA_PRESET, True, b'original\n', manager.LLAMA_SERVICE, ['mistral'], '0000:03:00.0', 'llama:mistral')
manager.wait_for_model = lambda model, target, timeout=40: False
try:
    manager.recover_journal()
    raise AssertionError('unverified journal recovery unexpectedly succeeded')
except RuntimeError as error:
    assert 'could not be verified' in str(error)
assert manager.JOURNAL_FILE.exists()
retry = manager.read_json(manager.JOURNAL_FILE, {})
retry['lastAttempt'] = 0
manager.write_json(manager.JOURNAL_FILE, retry)
manager.wait_for_model = lambda model, target, timeout=40: True
manager.recover_journal()
assert not manager.JOURNAL_FILE.exists()

# If the prior eGPU disappears during a crash, recovery rebuilds the preset for
# the stored internal fallback, verifies it, and keeps the eGPU preference.
manager.write_json(manager.STATE_FILE, {'models': {'llama:mistral': {
    'preferred': '0000:0e:00.0', 'fallback': '0000:03:00.0', 'wasLoaded': True,
    'runtimeMetadata': {'runtime': 'llama.cpp', 'routerId': 'mistral'},
}}})
internal_card = dict(transition_model, current='', devices=[], allowedDevices=['0000:03:00.0'])
manager.gpus = lambda: devices[:1]
manager.inventory = lambda: {'gpus': devices[:1], 'models': [internal_card], 'operation': {}}
verified = []
manager.wait_for_model = lambda model, target, timeout=40: verified.append(target) or target == '0000:03:00.0'
recovery_loads = []
def load_after_unplug(ids):
    recovery_loads.append(list(ids))
    if len(recovery_loads) == 1:
        raise RuntimeError('saved eGPU preset cannot load')
manager.load_router_models = load_after_unplug
manager.save_journal(manager.LLAMA_PRESET, True, b'egpu-preset\n', manager.LLAMA_SERVICE, ['mistral'], '0000:0e:00.0', 'llama:mistral')
manager.recover_journal()
recovered = manager.read_json(manager.STATE_FILE, {})['models']['llama:mistral']
assert verified == ['0000:03:00.0'] and recovery_loads == [['mistral'], ['mistral']]
assert recovered['preferred'] == '0000:0e:00.0' and recovered['lastGood'] == '0000:03:00.0'
assert not manager.JOURNAL_FILE.exists()
manager.load_router_models = lambda ids: loaded_sets.append(list(ids))
manager.gpus = lambda: devices

# EchoCraft journals the untouched environment before replace_env mutates it.
manager.ECHO_ENV = env
echo_card = {'id': 'echocraft-whisper', 'name': 'Whisper', 'runtime': 'EchoCraft / whisper.cpp',
             'capable': True, 'current': '0000:03:00.0', 'devices': ['0000:03:00.0'],
             'allowedDevices': ['0000:03:00.0'], 'fits': {'0000:03:00.0': {'status': 'fits'}}}
manager.inventory = lambda: {'gpus': devices, 'models': [echo_card], 'operation': {}}
real_replace_env = manager.replace_env
def journaled_replace(path, updates):
    assert manager.JOURNAL_FILE.exists()
    return real_replace_env(path, updates)
manager.replace_env = journaled_replace
manager.wait_for_model = lambda model, target, timeout=40: True
manager.transition('echocraft-whisper', '0000:03:00.0')
assert not manager.JOURNAL_FILE.exists()
manager.replace_env = real_replace_env

# If the eGPU disappears during an ordinary failed move, rollback must not
# restore its stale preset and call that success. It rebuilds and verifies the
# saved internal fallback while keeping the exact prior loaded set.
transition_model['current'] = '0000:0e:00.0'
transition_model['devices'] = ['0000:0e:00.0']
transition_model['loaded'] = True
inventory_calls = []
def disconnecting_inventory():
    inventory_calls.append(True)
    if len(inventory_calls) == 1:
        return {'gpus': devices, 'models': [transition_model], 'operation': {}}
    return {'gpus': devices[:1], 'models': [internal_card], 'operation': {}}
manager.inventory = disconnecting_inventory
manager.LLAMA_PRESET.write_text('baseline\n')
manager.write_json(manager.STATE_FILE, {'models': {'llama:mistral': {
    'preferred': '0000:0e:00.0', 'fallback': '0000:03:00.0', 'wasLoaded': True,
    'runtimeMetadata': {'runtime': 'llama.cpp', 'routerId': 'mistral'},
}}})
rollback_checks = []
def verify_rollback(model, target, timeout=40):
    rollback_checks.append(target)
    return len(rollback_checks) == 3 and target == '0000:03:00.0'
manager.wait_for_model = verify_rollback
try:
    manager.transition('llama:mistral', '0000:03:00.0')
    raise AssertionError('unverified load unexpectedly succeeded')
except RuntimeError as error:
    assert 'not verified' in str(error) and 'verified available GPU' in str(error)
assert rollback_checks == ['0000:03:00.0', '0000:0e:00.0', '0000:03:00.0']
assert manager.LLAMA_PRESET.read_text() == 'version = 1\n'
assert loaded_sets[-3:] == [['mistral', 'mistral'], ['mistral'], ['mistral']]
assert not manager.JOURNAL_FILE.exists()

# Stateful router regression: with priorLoaded empty and the router initially
# down, the selected model is explicitly POSTed to /load. It only reports an
# internal DRM allocation after that request and the fallback preset rewrite.
model_path = '/models/mistral.gguf'
router_state = {'loaded': False}
router_posts = []
class StatefulResponse:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *args): pass
def stateful_urlopen(request, timeout=0):
    assert request.method == 'POST' and request.full_url.endswith('/load')
    payload = __import__('json').loads(request.data)
    router_posts.append(payload['model'])
    router_state['loaded'] = True
    return StatefulResponse()
manager.urllib.request.urlopen = stateful_urlopen
manager.router_models = lambda: ([{
    'id': 'mistral', 'status': {'value': 'loaded', 'args': ['llama-server', '--model', model_path]},
    'meta': {'size': 1234},
}] if router_state['loaded'] else [])
manager.user_processes = lambda proc: iter(([(77, 'llama-server', ['llama-server', '--model', model_path])] if router_state['loaded'] else []))
manager.process_allocations = lambda pid, proc: ({'0000:03:00.0': 4096} if 'Vulkan-0000:03:00.0' in manager.LLAMA_PRESET.read_text() else {})
manager.gpus = lambda: devices[:1]
manager.inventory = real_inventory
manager.wait_for_model = real_wait_for_model
manager.load_router_models = real_load_router_models
manager.preset_text = real_preset_text
manager.restart = lambda service: router_state.update(loaded=False)
manager.write_json(manager.STATE_FILE, {'models': {'llama:mistral': {
    'preferred': '0000:0e:00.0', 'fallback': '0000:03:00.0', 'wasLoaded': True,
    'runtimeMetadata': {'runtime': 'llama.cpp', 'routerId': 'mistral', 'name': 'mistral',
                        'path': model_path, 'qwen': False, 'required': 1234},
}}})
manager.LLAMA_PRESET.write_text('[mistral]\ndevice = Vulkan-0000:0e:00.0\n')
manager.save_journal(manager.LLAMA_PRESET, True, manager.LLAMA_PRESET.read_bytes(), manager.LLAMA_SERVICE,
                     [], '0000:0e:00.0', 'llama:mistral', 'mistral', True)
manager.recover_journal()
assert router_posts == ['mistral', 'mistral']
assert real_inventory()['models'][0]['devices'] == ['0000:03:00.0']
assert not manager.JOURNAL_FILE.exists()

# The same empty-router snapshot is covered through an ordinary transition
# rollback. The first verification fails after a real load POST; rollback then
# reloads the selected model and verifies the internal fallback before cleanup.
router_state['loaded'] = False
router_posts.clear()
manager.LLAMA_PRESET.write_text('[mistral]\ndevice = Vulkan-0000:0e:00.0\n')
manager.write_json(manager.OPERATION_FILE, {})
wait_calls = []
def fail_first_verification(model, target, timeout=40):
    wait_calls.append(target)
    if len(wait_calls) == 1:
        return False
    return real_wait_for_model(model, target, timeout=2)
manager.wait_for_model = fail_first_verification
try:
    manager.transition('llama:mistral', '0000:03:00.0', remember=False, recover=True)
    raise AssertionError('ordinary rollback fixture unexpectedly succeeded')
except RuntimeError as error:
    assert 'verified available GPU' in str(error)
assert router_posts == ['mistral', 'mistral', 'mistral']
assert real_inventory()['models'][0]['devices'] == ['0000:03:00.0']
assert not manager.JOURNAL_FILE.exists()
manager.wait_for_model = real_wait_for_model

# Router-down recovery reconstructs persisted metadata and does not skip the
# temporarily incapable row when moving to the stored internal fallback.
manager.write_json(manager.STATE_FILE, {'models': {'llama:mistral': {
    'preferred': '0000:0e:00.0', 'fallback': '0000:03:00.0', 'wasLoaded': True,
    'runtimeMetadata': {'runtime': 'llama.cpp', 'routerId': 'mistral', 'name': 'mistral',
                        'path': '/models/mistral.gguf', 'qwen': False, 'required': 1024},
}}})
manager.gpus = lambda: devices[:1]
manager.user_processes = lambda proc: iter([])
manager.router_models = lambda: []
manager.echo_model = lambda processes: None
manager.inventory = real_inventory
manager.write_json(manager.OPERATION_FILE, {})
down = manager.inventory()
assert down['models'][0]['reason'].startswith('The llama router is unavailable')
recoveries = []
manager.transition = lambda model, target, remember=False, recover=False: recoveries.append((model, target, recover))
manager.reconcile()
assert recoveries == [('llama:mistral', '0000:03:00.0', True)]

recoveries.clear()
manager.router_models = lambda: [{'id': 'mistral', 'status': {'value': 'error', 'args': ['llama-server', '--model', '/models/mistral.gguf']}}]
manager.reconcile()
assert recoveries == [('llama:mistral', '0000:03:00.0', True)]
assert manager.read_json(manager.STATE_FILE, {})['models']['llama:mistral']['wasLoaded'] is True

# Stale in-progress state expires instead of wedging the bar forever.
manager.write_json(manager.OPERATION_FILE, {'status': 'loading', 'message': 'old', 'updated': 0})
assert manager.operation()['status'] == 'error'
PY
pass "GPU allocation, user-selected presets, and atomic EchoCraft updates are deterministic"

rg -F '"offloading"' "$manager" >/dev/null || fail "the manager reports an offloading stage"
rg -F '"unloading"' "$manager" >/dev/null || fail "the manager reports an unloading stage"
rg -F '"loading"' "$manager" >/dev/null || fail "the manager reports a loading stage"
rg -F 'Rollback remains pending and will retry:' "$manager" >/dev/null ||
  fail "the manager retains and surfaces an unverified rollback"
rg -F 'service=ECHO_SERVICE' "$manager" >/dev/null || fail "placement reloads EchoCraft"
rg -F 'wait_for_model(model_id,target)' "$manager" >/dev/null || fail "placement verifies the requested DRM device"
rg -q '<[[:space:]]*300' "$manager" >/dev/null || fail "automatic placement failures have a retry backoff"
! rg -q 'notify-send' "$manager" || fail "the model manager bypasses the Omarchy notification helper"
pass "model transitions expose stages, reload, verify, rollback, and notify through miaOS"

rg -F 'Install ggml-vulkan to enable the llama.cpp Vulkan backend.' "$manager" >/dev/null ||
  fail "the llama adapter explains its missing modular Vulkan backend"
rg -F 'n-gpu-layers = all' "$manager" >/dev/null || fail "llama presets offload model layers"
! rg -qi 'qwen' "$manager" || fail "the manager contains model-name-specific GPU policy"
rg -F '"-r",str(nid)' "$manager" >/dev/null || fail "progress notifications replace one visible notification"
pass "llama placement is user-selectable and progress replaces one notification"

rg -F 'text: "Apply & reload"' "$widget" >/dev/null || fail "the widget exposes explicit reload semantics"
rg -F 'managerPath, "reconcile"' "$widget" >/dev/null || fail "the widget reconciles returning eGPUs"
rg -F 'root.inventory.operation.message' "$widget" >/dev/null || fail "the widget displays transition banners"
rg -F 'property bool available: modelCard.modelData.capable' "$widget" >/dev/null ||
  fail "unsupported runtime controls are disabled"
pass "the GPU popup exposes placement, fit, apply/reload, progress, and capability state"

rg -F 'Timer { interval: 15000; repeat: true; running: true; onTriggered: root.refresh() }' "$widget" >/dev/null ||
  fail "inventory polling is throttled to 15 seconds"
rg -F 'interval: 30000' "$widget" >/dev/null || fail "reconciliation is throttled to 30 seconds"
[[ $(rg -F '!probe.running && !reconcile.running && !action.running' "$widget" | wc -l) == 2 ]] ||
  fail "inventory and reconciliation both exclude every other worker"
rg -F 'if (!model || !device || probe.running || reconcile.running || action.running) return' "$widget" >/dev/null ||
  fail "model actions cannot overlap"
! rg -F 'if (!reconcile.running) reconcile.running = true' "$widget" >/dev/null ||
  fail "startup cannot launch inventory and reconciliation together"
rg -F 'root.refresh(); root.toggle()' "$widget" >/dev/null ||
  fail "clicking the GPU widget still requests an immediate refresh"
pass "GPU polling is throttled, serialized, and refreshes on click"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/.config/omarchy/plugins/mantis.egpu"
mkdir -p "$test_tmp/.config/omarchy"
cat >"$test_tmp/.config/omarchy/plugins/mantis.egpu/manifest.json" <<'JSON'
{"schemaVersion":1,"id":"mantis.egpu"}
JSON
printf 'prototype\n' >"$test_tmp/.config/omarchy/plugins/mantis.egpu/Widget.qml"
printf '{"bar":{"layout":{"right":[{"id": "mantis.egpu"}]}}}\n' >"$test_tmp/.config/omarchy/shell.json"

HOME="$test_tmp" bash -euo pipefail "$migration" >/dev/null
retired="$test_tmp/.config/omarchy/plugins/.retired-mantis.egpu-1790805582"
[[ ! -e $test_tmp/.config/omarchy/plugins/mantis.egpu && -f $retired/Widget.qml ]] ||
  fail "the migration preserves and retires the local prototype"
grep -Fq '"id": "omarchy.egpu"' "$test_tmp/.config/omarchy/shell.json" ||
  fail "the migration updates the bar layout to the first-party plugin ID"
HOME="$test_tmp" bash -euo pipefail "$migration" >/dev/null
[[ -f $retired/Widget.qml ]] || fail "the prototype retirement remains idempotent"
pass "the migration preserves the local prototype while handing its ID to the OS"

# A new migration reaches users for whom the earlier prototype-only migration
# already completed, inserts the first-party widget, and removes GPU duplicates
# without touching the unrelated hardware telemetry widget.
printf '%s\n' '{"bar":{"layout":{"left":[{"id":"mantis.hardware"},{"id":"mantis.egpu","custom":"keep","size":42}],"right":[{"id":"omarchy.tray"},{"id":"mantis.egpu"},{"id":"omarchy.egpu"},{"id":"omarchy.agents"}]}}}' >"$test_tmp/.config/omarchy/shell.json"
HOME="$test_tmp" bash -euo pipefail "$layout_migration" >/dev/null
[[ $(jq '[.bar.layout[][] | select(.id == "omarchy.egpu")] | length' "$test_tmp/.config/omarchy/shell.json") == 1 ]] ||
  fail "the new migration leaves exactly one GPU widget"
jq -e '.bar.layout[][] | select(.id == "mantis.hardware")' "$test_tmp/.config/omarchy/shell.json" >/dev/null ||
  fail "the GPU migration preserves mantis.hardware"
jq -e '.bar.layout.left[1] == {"id":"omarchy.egpu","custom":"keep","size":42} and ([.bar.layout.right[].id] | all(. != "omarchy.egpu" and . != "mantis.egpu"))' \
  "$test_tmp/.config/omarchy/shell.json" >/dev/null || fail "the first GPU object keeps its section, position, and custom fields"
before=$(sha256sum "$test_tmp/.config/omarchy/shell.json")
HOME="$test_tmp" bash -euo pipefail "$layout_migration" >/dev/null
[[ $before == $(sha256sum "$test_tmp/.config/omarchy/shell.json") ]] || fail "the new GPU layout migration is idempotent"
pass "the new migration inserts and deduplicates one GPU widget without touching hardware telemetry"

printf '%s\n' '{"bar":{"layout":{"left":[{"id":"mantis.hardware"}],"right":[{"id":"omarchy.tray"},{"id":"omarchy.agents"},{"id":"omarchy.power"}]}}}' >"$test_tmp/.config/omarchy/shell.json"
HOME="$test_tmp" bash -euo pipefail "$layout_migration" >/dev/null
[[ $(jq -c '[.bar.layout.right[].id]' "$test_tmp/.config/omarchy/shell.json") == '["omarchy.tray","omarchy.egpu","omarchy.agents","omarchy.power"]' ]] ||
  fail "the new migration inserts the GPU widget for users without the prototype"
pass "the new migration reaches existing layouts that never had mantis.egpu"

printf '%s\n' '{"bar":{"layout":{"left":["mantis.egpu","omarchy.clock"],"right":[{"id":"omarchy.egpu","custom":"later"}]}}}' >"$test_tmp/.config/omarchy/shell.json"
HOME="$test_tmp" bash -euo pipefail "$layout_migration" >/dev/null
[[ $(jq -c '.bar.layout' "$test_tmp/.config/omarchy/shell.json") == '{"left":["omarchy.egpu","omarchy.clock"],"right":[]}' ]] ||
  fail "string-form first occurrence keeps string representation and global position"
pass "the migration preserves string representation for the true first GPU occurrence"

shell_target="$test_tmp/.config/omarchy/shell-real.json"
mv "$test_tmp/.config/omarchy/shell.json" "$shell_target"
ln -s "$shell_target" "$test_tmp/.config/omarchy/shell.json"
chmod 640 "$shell_target"
HOME="$test_tmp" bash -euo pipefail "$layout_migration" >/dev/null
[[ -L $test_tmp/.config/omarchy/shell.json ]] || fail "the migration preserves the shell config symlink"
[[ $(stat -c %a "$shell_target") == 640 ]] || fail "the migration preserves the shell config mode"
pass "the migration preserves shell config symlink target and mode"

jq -e '.bar.layout.right | any(.id == "omarchy.egpu")' "$ROOT/config/omarchy/shell.json" >/dev/null ||
  fail "fresh user configuration enables the GPU popup"
pass "fresh user configuration enables the packaged GPU popup"
