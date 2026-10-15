echo "Enable Vulkan placement support for local llama.cpp models"

omarchy-pkg-add ggml-vulkan

preset="$HOME/.config/omarchy/egpu/llama-models.ini"
dropin="$HOME/.config/systemd/user/mia-local-llm.service.d/20-omarchy-gpu-placement.conf"
mkdir -p "${preset%/*}" "${dropin%/*}"
if [[ ! -f $preset ]]; then
  install -m600 /dev/null "$preset"
  printf 'version = 1\n' >"$preset"
fi
install -m644 \
  "$OMARCHY_PATH/default/systemd/user/mia-local-llm.service.d/20-omarchy-gpu-placement.conf" \
  "$dropin"
systemctl --user daemon-reload
if systemctl --user is-active --quiet mia-local-llm.service; then
  systemctl --user restart mia-local-llm.service
fi
