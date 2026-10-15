echo "Enable the first-party GPU widget and retire duplicate prototypes"

shell_config="$HOME/.config/omarchy/shell.json"
prototype="$HOME/.config/omarchy/plugins/mantis.egpu"
retired="$HOME/.config/omarchy/plugins/.retired-mantis.egpu-1790809281"

if [[ -s $shell_config ]]; then
  shell_target=$(readlink -f "$shell_config")
  [[ -n $shell_target && -f $shell_target ]] || {
    echo "Could not resolve the shell configuration at $shell_config" >&2
    exit 1
  }
  tmp=$(mktemp)
  jq '
    def id: if type == "string" then . else (.id // "") end;
    def gpu: (id == "omarchy.egpu" or id == "mantis.egpu");
    def normalize_gpu: if type == "string" then "omarchy.egpu" else .id = "omarchy.egpu" end;
    def dedupe_gpu:
      reduce to_entries[] as $section ({seen: false, layout: {}};
        .layout[$section.key] = [] |
        reduce $section.value[] as $entry (.;
          if ($entry | gpu) then
            if .seen then . else .seen = true | .layout[$section.key] += [($entry | normalize_gpu)] end
          else .layout[$section.key] += [$entry]
          end)) | .layout;
    def insert_widget:
      ([range(0; length) as $i | select((.[$i] | id) == "omarchy.agents") | $i][0]) as $agents |
      ([range(0; length) as $i | select((.[$i] | id) == "omarchy.tray") | $i][0]) as $tray |
      if $agents != null then .[0:$agents] + [{id: "omarchy.egpu"}] + .[$agents:]
      elif $tray != null then .[0:$tray + 1] + [{id: "omarchy.egpu"}] + .[$tray + 1:]
      else . + [{id: "omarchy.egpu"}]
      end;
    if any((.bar.layout // {}) | to_entries[]; any(.value[]?; gpu)) then
      .bar.layout |= dedupe_gpu
    else
      .bar.layout.right |= ((. // []) | insert_widget)
    end
  ' "$shell_target" >"$tmp" && chmod --reference="$shell_target" "$tmp" && mv "$tmp" "$shell_target" || {
    rm -f "$tmp"
    echo "Could not update the shell GPU widget layout" >&2
    exit 1
  }
fi

if [[ -d $prototype && -f $prototype/manifest.json ]] &&
  jq -e '.id == "mantis.egpu"' "$prototype/manifest.json" >/dev/null 2>&1; then
  [[ ! -e $retired ]] || {
    echo "Cannot retire $prototype because $retired already exists" >&2
    exit 1
  }
  mv "$prototype" "$retired"
fi
