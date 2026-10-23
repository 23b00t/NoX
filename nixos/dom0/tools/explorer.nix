{ pkgs, vmRegistry, ... }:
let
  yaziVms = map (vm: vm.name) (vmRegistry.vmHasFeature "yazi");
in
pkgs.writeShellScriptBin "explorer" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # Create an array of VM names that have the "yazi" feature
  vms=(
    ${builtins.concatStringsSep " " (map (n: "\"${n}\"") yaziVms)}
  )

  # Populate rofi with it
  selected=$(printf '%s\n' "''${vms[@]}" | rofi -dmenu -i -p "Start VM" -theme /etc/xdg/rofi/config.rasi)

  # If a selection was made, start the corresponding VM and open yazi in it
  [ -n "$selected" ] || exit 0
  # foot in the VM over wprs (image previews stay in the VM)
  exec vm-run "$selected" foot yazi
''
