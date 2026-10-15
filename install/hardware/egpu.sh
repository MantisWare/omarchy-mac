# Install the narrowly allowlisted Thunderbolt authorization path on every
# machine. It remains dormant without a catalogued eGPU enclosure.
install -Dm644 \
  "$OMARCHY_PATH/default/udev/90-omarchy-egpu.rules" \
  /etc/udev/rules.d/90-omarchy-egpu.rules

# llama.cpp splits GPU support into backend packages. Install the Vulkan
# backend so model placement is available without replacing the runtime.
omarchy-pkg-add ggml-vulkan
