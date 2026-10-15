# External GPU support

miaOS treats an eGPU as two independent hardware layers:

- A Thunderbolt PCIe enclosure must be authorized before the kernel creates its PCIe tunnel.
- A PCI display controller behind that tunnel is handled by its ordinary kernel driver and modalias (`amdgpu`, `xe`/`i915`, `nouveau`, or the installed NVIDIA driver).

This separation keeps the implementation generic. There are no enclosure UUIDs, GPU serial numbers, or one-off rules for a particular card.

## Compatibility catalogs

`default/egpu/enclosures.tsv` is the authorization allowlist. Each entry uses the stable Thunderbolt vendor and device identifiers exposed by sysfs. `bin/omarchy-hw-egpu-authorize` normalizes those identifiers, authorizes an exact catalog match at the Thunderbolt `user` security level, and ignores every other device. At the `secure` security level, boltd remains responsible for key enrollment and challenge-based authorization.

`default/egpu/gpus.tsv` records representative PCI IDs, expected kernel drivers, and validation state. It is documentation and test evidence rather than an authorization gate: after a PCIe tunnel exists, Linux module aliases bind any supported PCI display controller in the normal way. Add newly verified cards to the catalog without adding device-specific execution paths.

Catalog states are:

- `verified`: exercised on miaOS with the exact identity in the row.
- `compatible`: covered by the documented Thunderbolt PCIe or kernel-driver path, but not yet tested in that exact miaOS pairing.

For an enclosure, record its `vendor` and `device` values from `/sys/bus/thunderbolt/devices/<route>/`. For a GPU, record the numeric PCI identity and bound driver from `lspci -nnk`.

## Installation and updates

Fresh installs copy `default/udev/90-omarchy-egpu.rules` into `/etc/udev/rules.d` from `install/hardware/egpu.sh`. Existing installs receive the same rule through migration `1790804830.sh`. The rule delegates to the root-owned packaged helper instead of embedding writable checkout or home-directory paths in a privileged udev action.

T2 firmware can expose a prefetchable Thunderbolt window smaller than a modern GPU's 256 MiB BAR. `install/hardware/apple/fix-t2.sh` therefore adds `pci=realloc,hpmmioprefsize=512M` to the T2 Limine command line on fresh installs. Migration `1790804830.sh` adds it to existing T2 installs, rebuilds the UKI through `limine-mkinitcpio`, and records a machine-wide marker so a second user's migration does not repeat the rebuild before reboot.

## Validation

After connecting an enclosure:

1. `boltctl list` should show an authorized device and the negotiated link speed.
2. `lspci -nnk` should show the external display controller and its kernel driver.
3. The booted command line on a T2 Mac should contain `pci=realloc,hpmmioprefsize=512M`.

The first verified combination is a MacBookPro16,1, an inXtron AKiTiO Node (`0x0041:0x0308`), and a Radeon RX 6600 XT (`1002:73ff`) over a certified 40 Gb/s Thunderbolt 3 cable.

## Local-model placement

The local `mantis.egpu` prototype has become the first-party `omarchy.egpu` bar widget under `shell/plugins/egpu/`. It reports physical GPUs, whole-device VRAM telemetry, loaded local-model runtimes, observed DRM allocations, and each model's stored preferred device. Preferences live in `~/.local/state/omarchy/egpu-model-placement.json`. The active target uses its PCI address, and the manager also stores vendor, device, and external-placement identity so a uniquely matching eGPU can be recovered if its PCI address changes after reconnecting on another port.

A runtime is actionable only when its adapter can perform all three stages: configure the selected GPU, reload the model, and verify a positive DRM allocation on the requested PCI device. EchoCraft selects Mesa devices through `DRI_PRIME`, restarts `echocraft.service`, and verifies the worker's `/proc/<pid>/fdinfo` evidence. It is actionable only when the actual running executable, or EchoCraft's pinned backend in `~/.config/echo-craft/bin/whisper-vulkan/`, contains compiled Vulkan support; stock CPU-only or not-yet-downloaded backends remain disabled with a precise reason. The llama.cpp adapter manages per-model router presets and restarts `mia-local-llm.service`; fresh installs and migration `1790806724.sh` install the modular `ggml-vulkan` backend and the `LLAMA_ARG_MODELS_PRESET` systemd drop-in. If that backend is absent or reports no devices, the popup gives the precise disabled reason.

Whisper and every llama.cpp model may be assigned to any GPU supported by its runtime; model names never influence placement policy. Existing loaded models remain on their observed device until the user chooses another one. Without a saved choice or observed allocation, a model prefers a present eGPU and otherwise uses the first selectable GPU. Preferences and fallbacks are persisted by hardware identity, and a model automatically returns to its preferred GPU after reconnect. The manager derives llama device names by restricting Mesa enumeration with the target PCI address rather than hard-coding a Vulkan ordinal, while ignoring volatile free-VRAM text when mapping that result back to the stable Vulkan index. Because Vulkan can open DRM nodes and create small bookkeeping allocations on several GPUs, the manager treats the GPU with the dominant allocation as the model's placement; this prevents reconciliation loops caused by incidental allocations. VRAM need is a conservative estimate of model data, multimodal projector data, and runtime/KV margin when those inputs are known; otherwise it is shown as unknown and the router's fit check plus observed allocation remain authoritative. A router restart explicitly reloads the selected model and the previously loaded set through the router API, and is not reported as successful until positive dominant DRM allocation is observed on the selected device. CPU-only ComfyUI remains visible but disabled until it has the same configure/reload/verify contract.

Apply means unload and reload, not live VRAM migration. The widget displays a banner during offload, unload, and load stages, while one persistent top-level notification is updated in place to avoid notification spam. A successful transition updates the last-known-good device. On failure, the manager restores the previous runtime configuration, restarts it, verifies the fallback when possible, and surfaces the error both in the widget and through that notification.

The widget periodically reconciles preferences. When a preferred eGPU disconnects, a configured built-in fallback is restored; when that eGPU returns, the same verified reload path moves the model back automatically. A file lock serializes manual and automatic transitions, and an automatic failure is held for five minutes before retrying so a broken device cannot create a restart loop.

Migration `1790809281.sh` reaches existing users regardless of whether the prototype migration already completed. It inserts `omarchy.egpu` when absent, converts and deduplicates `mantis.egpu`/`omarchy.egpu` entries while preserving unrelated bar widgets and ordering, and retires the older local prototype without touching `mantis.hardware`. The single GPU widget keeps its hover text concise; inventory and per-model controls live together in its click popover.
