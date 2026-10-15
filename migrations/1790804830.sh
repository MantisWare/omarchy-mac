echo "Enable catalogued Thunderbolt eGPUs and reserve T2 PCI hot-plug resources"

rule_source="$OMARCHY_PATH/default/udev/90-omarchy-egpu.rules"
rule_target="${OMARCHY_EGPU_UDEV_RULE:-/etc/udev/rules.d/90-omarchy-egpu.rules}"
udev_control="${OMARCHY_EGPU_UDEV_CONTROL:-/run/udev/control}"
limine_conf="${OMARCHY_T2_LIMINE_CONF:-/etc/limine-entry-tool.d/t2-mac.conf}"
legacy_limine_conf="${OMARCHY_EGPU_LEGACY_LIMINE_CONF:-/etc/limine-entry-tool.d/egpu-hotplug.conf}"
running_cmdline="${OMARCHY_T2_RUNNING_CMDLINE:-/proc/cmdline}"
repair_marker="${OMARCHY_EGPU_REPAIR_MARKER:-/var/lib/omarchy/migrations/1790804830}"
hotplug_param="pci=realloc,hpmmioprefsize=512M"

maintained_config_has_hotplug_param() {
  [[ -f $limine_conf ]] &&
    grep -E '^[[:space:]]*KERNEL_CMDLINE\[[^]]+\]\+=' "$limine_conf" |
      grep -Eq '(^|[[:space:]"])pci=realloc,hpmmioprefsize=512M([[:space:]"]|$)'
}

if [[ ! -f $rule_target ]] || ! cmp -s "$rule_source" "$rule_target"; then
  sudo install -Dm644 "$rule_source" "$rule_target"
  if [[ -e $udev_control ]]; then
    sudo /usr/bin/udevadm control --reload
  fi
fi

pci_devices=$(lspci -Dn)
grep -Eq '106b:180[12]' <<<"$pci_devices" || exit 0

needs_rebuild=0
if [[ -f $limine_conf ]] && ! maintained_config_has_hotplug_param; then
  sudo sed -i \
    "/^KERNEL_CMDLINE\[default\]+=/ s/\"[[:space:]]*$/ $hotplug_param\"/" \
    "$limine_conf"
  maintained_config_has_hotplug_param || {
    echo "Could not add the eGPU PCI hot-plug resource reservation to $limine_conf" >&2
    exit 1
  }
  needs_rebuild=1
fi

# The first diagnosed machine received this narrow drop-in live. Fold an exact
# copy into the maintained T2 configuration; preserve any administrator-edited
# variant rather than guessing which custom command line is safe to remove.
if maintained_config_has_hotplug_param &&
  [[ -f $legacy_limine_conf ]] &&
  [[ $(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$legacy_limine_conf") == \
    'KERNEL_CMDLINE[default]+=" pci=realloc,hpmmioprefsize=512M"' ]]; then
  sudo rm -f "$legacy_limine_conf"
  needs_rebuild=1
fi

# A migration marker makes this machine-wide step idempotent for other users
# before the rebuilt command line has had a reboot in which to become visible.
if [[ -f $limine_conf && ! -e $repair_marker ]] && {
  [[ ! -r $running_cmdline ]] || ! grep -Fqw "$hotplug_param" "$running_cmdline"
}; then
  needs_rebuild=1
fi

if (( needs_rebuild )); then
  sudo limine-mkinitcpio
  sudo install -Dm644 /dev/null "$repair_marker"
fi
