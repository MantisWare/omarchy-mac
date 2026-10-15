#!/bin/bash

mkdir -p "$HOME/.config/omarchy/egpu" "$HOME/.config/systemd/user/mia-local-llm.service.d"
if [[ ! -f $HOME/.config/omarchy/egpu/llama-models.ini ]]; then
  install -m600 /dev/null "$HOME/.config/omarchy/egpu/llama-models.ini"
  printf 'version = 1\n' >"$HOME/.config/omarchy/egpu/llama-models.ini"
fi
install -m644 \
  "$OMARCHY_PATH/default/systemd/user/mia-local-llm.service.d/20-omarchy-gpu-placement.conf" \
  "$HOME/.config/systemd/user/mia-local-llm.service.d/20-omarchy-gpu-placement.conf"
systemctl --user daemon-reload
