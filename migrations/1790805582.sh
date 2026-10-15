echo "Move the local eGPU prototype aside for the packaged GPU manager"

prototype="$HOME/.config/omarchy/plugins/mantis.egpu"
retired="$HOME/.config/omarchy/plugins/.retired-mantis.egpu-1790805582"
shell_config="$HOME/.config/omarchy/shell.json"

if [[ -f $shell_config ]] && grep -Eq '"id"[[:space:]]*:[[:space:]]*"mantis\.egpu"' "$shell_config"; then
  shell_target=$(readlink -f "$shell_config")
  [[ -n $shell_target && -f $shell_target ]] || {
    echo "Could not resolve the shell configuration at $shell_config" >&2
    exit 1
  }
  sed -Ei 's/("id"[[:space:]]*:[[:space:]]*)"mantis\.egpu"/\1"omarchy.egpu"/g' "$shell_target"
fi

if [[ -d $prototype && -f $prototype/manifest.json ]] &&
  jq -e '.id == "mantis.egpu"' "$prototype/manifest.json" >/dev/null 2>&1; then
  if [[ -e $retired ]]; then
    echo "Cannot retire $prototype because the preserved destination already exists: $retired" >&2
    exit 1
  fi

  mv "$prototype" "$retired"
  echo "Preserved the former local GPU plugin at $retired"
fi
