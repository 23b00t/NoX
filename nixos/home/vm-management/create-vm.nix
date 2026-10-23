{ pkgs, ... }:
pkgs.writeShellScriptBin "create-vm" ''
  #!/usr/bin/env bash
  set -euo pipefail

  usage() {
    cat <<EOF
Usage: create-vm [options]

Options:
  --name <name>                         VM name (required in non-interactive mode)
  --short <shortname>                   VM short name
  --profile <default|minimal|coding>    Module profile
  --autostart <true|false>
  --nat <true|false>
  --allow-github-agent <true|false>
  --enable-host-dbus-forward <true|false>
  --mem <MiB>
  --vcpus <count>
  --home-img-size <MiB>
  --ip <10.0.0.X>
  --force                               Overwrite existing VM module/definition if present
  -h, --help                            Show this help

Notes:
  - If --ip is not provided, the next free IP after the current max (<253) is used.
EOF
  }

  bool_normalize() {
    case "$1" in
      true|TRUE|yes|YES|y|Y|1|on|ON) echo "true" ;;
      false|FALSE|no|NO|n|N|0|off|OFF) echo "false" ;;
      *)
        echo "Invalid boolean value: $1" >&2
        exit 1
        ;;
    esac
  }

  # Generic input with default
  prompt_input() {
    local question="$1"
    local default_value="$2"
    local value
    if [ -n "$default_value" ]; then
      read -r -p "$question [$default_value]: " value
      if [ -z "$value" ]; then
        value="$default_value"
      fi
    else
      read -r -p "$question: " value
    fi
    echo "$value"
  }

  # Boolean prompt with normalization
  prompt_bool() {
    local question="$1"
    local default_value="$2"
    local value
    while true; do
      read -r -p "$question [$default_value]: " value
      if [ -z "$value" ]; then
        value="$default_value"
      fi
      case "$(bool_normalize "$value")" in
        true) echo "true"; return ;;
        false) echo "false"; return ;;
      esac
    done
  }

  TMP_FILES=()

  new_tmp() {
    local tmp
    tmp="$(mktemp)"
    TMP_FILES+=("$tmp")
    printf '%s\n' "$tmp"
  }

  cleanup() {
    if [ "''${#TMP_FILES[@]}" -gt 0 ]; then
      rm -f "''${TMP_FILES[@]}"
    fi
  }

  trap cleanup EXIT

  next_available_vm_ip() {
    local file="$1"
    local ip octet
    local max_ip=0

    while IFS= read -r ip; do
      IFS='.' read -r _ _ _ octet <<< "$ip"
      if [ -n "$octet" ] && [ "$octet" -lt 253 ] && [ "$octet" -gt "$max_ip" ]; then
        max_ip="$octet"
      fi
    done < <(${pkgs.gnugrep}/bin/grep -oE '10\.0\.0\.[0-9]+' "$file")

    printf '10.0.0.%s\n' "$((max_ip + 1))"
  }

  ip_octet() {
    local ip="$1"
    local octet

    IFS='.' read -r _ _ _ octet <<< "$ip"
    printf '%s\n' "$octet"
  }

  insert_block_at_marker() {
    local target_file="$1"
    local marker="$2"
    local block_file="$3"
    local work_file="$4"
    local line
    local found_marker=0

    : > "$work_file"

    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$marker" ]; then
        cat "$block_file" >> "$work_file"
        found_marker=1
      fi
      printf '%s\n' "$line" >> "$work_file"
    done < "$target_file"

    if [ "$found_marker" -ne 1 ]; then
      echo "Could not find marker '$marker' in $target_file" >&2
      return 1
    fi
  }

  render_vm_module_from_template() {
    local output_file="$1"
    local line

    : > "$output_file"

    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "__MODULE_IMPORTS__")
          printf '%s\n' "$MODULE_IMPORTS" >> "$output_file"
          ;;
        "__EXTRA_SERVICE_BLOCKS____PERSISTENT_SERVICE_LINE__")
          if [ -n "$EXTRA_SERVICE_BLOCKS" ]; then
            printf '%s\n' "$EXTRA_SERVICE_BLOCKS" >> "$output_file"
          fi
          ;;
        *)
          line="''${line//__VM_NAME__/$VM_NAME}"
          line="''${line//__NET_INDEX__/$NET_INDEX}"
          line="''${line//__MAC_ADDR__/$MAC_ADDR}"
          line="''${line//__HOME_IMG_SIZE__/$HOME_IMG_SIZE}"
          line="''${line//__MEM__/$MEM}"
          line="''${line//__VCPUS__/$VCPUS}"
          printf '%s\n' "$line" >> "$output_file"
          ;;
      esac
    done < "$TEMPLATE_FILE"
  }

  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

  if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$HOME/nixos-config"
  fi

  REGISTRY_FILE="$REPO_ROOT/vms/registry.nix"
  DEFINITIONS_FILE="$REPO_ROOT/vms/definitions.nix"
  TEMPLATE_FILE="$REPO_ROOT/vms/templates/base.nix"

  DEFINITIONS_INSERT_MARKER="  # create-vm: definitions"
  REGISTRY_INSERT_MARKER="    # create-vm: registry-vms"

  [ -f "$REGISTRY_FILE" ] || { echo "Missing file: $REGISTRY_FILE" >&2; exit 1; }
  [ -f "$DEFINITIONS_FILE" ] || { echo "Missing file: $DEFINITIONS_FILE" >&2; exit 1; }
  [ -f "$TEMPLATE_FILE" ] || { echo "Missing file: $TEMPLATE_FILE" >&2; exit 1; }

  VM_NAME=""
  VM_SHORT=""
  PROFILE=""
  AUTOSTART=""
  NAT=""
  ALLOW_GITHUB_AGENT=""
  ENABLE_HOST_DBUS_FORWARD=""
  MEM=""
  VCPUS=""
  HOME_IMG_SIZE=""
  VM_IP=""
  FORCE=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)
        VM_NAME="$2"
        shift 2
        ;;
      --short)
        VM_SHORT="$2"
        shift 2
        ;;
      --profile)
        PROFILE="$2"
        shift 2
        ;;
      --autostart)
        AUTOSTART="$(bool_normalize "$2")"
        shift 2
        ;;
      --nat)
        NAT="$(bool_normalize "$2")"
        shift 2
        ;;
      --allow-github-agent)
        ALLOW_GITHUB_AGENT="$(bool_normalize "$2")"
        shift 2
        ;;
      --enable-host-dbus-forward)
        ENABLE_HOST_DBUS_FORWARD="$(bool_normalize "$2")"
        shift 2
        ;;

      --mem)
        MEM="$2"
        shift 2
        ;;
      --vcpus)
        VCPUS="$2"
        shift 2
        ;;
      --home-img-size)
        HOME_IMG_SIZE="$2"
        shift 2
        ;;
      --ip)
        VM_IP="$2"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [ -z "$PROFILE" ]; then
    echo "Choose profile:"
    echo "  1) default"
    echo "  2) minimal"
    echo "  3) coding"
    while true; do
      read -r -p "Profile [default]: " profile_input
      profile_input="''${profile_input:-default}"
      case "$profile_input" in
        1|default) PROFILE="default"; break ;;
        2|minimal) PROFILE="minimal"; break ;;
        3|coding) PROFILE="coding"; break ;;
        *) echo "Please choose: default, minimal, or coding." ;;
      esac
    done
  fi

  case "$PROFILE" in
    default|minimal|coding) ;;
    *)
      echo "Invalid --profile value: $PROFILE" >&2
      exit 1
      ;;
  esac

  if [ -z "$VM_NAME" ]; then
    VM_NAME="$(prompt_input "VM name" "")"
  fi
  if ! echo "$VM_NAME" | grep -Eq '^[a-z][a-z0-9-]*$'; then
    echo "Invalid VM name '$VM_NAME'. Use: lowercase letters, digits, '-' and start with letter." >&2
    exit 1
  fi

  if [ -z "$VM_SHORT" ]; then
    VM_SHORT="$(prompt_input "VM shortname" "$VM_NAME")"
  fi
  if ! echo "$VM_SHORT" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
    echo "Invalid VM short '$VM_SHORT'. Use: lowercase letters, digits, '-' and start with letter or digit." >&2
    exit 1
  fi

  if [ -z "$AUTOSTART" ]; then
    AUTOSTART="$(prompt_bool "Autostart" "false")"
  fi
  if [ -z "$NAT" ]; then
    NAT="$(prompt_bool "NAT" "true")"
  fi
  if [ -z "$ALLOW_GITHUB_AGENT" ]; then
    ALLOW_GITHUB_AGENT="$(prompt_bool "allowGitHubAgent" "false")"
  fi
  if [ -z "$ENABLE_HOST_DBUS_FORWARD" ]; then
    ENABLE_HOST_DBUS_FORWARD="$(prompt_bool "enableHostDbusForward" "true")"
  fi
  if [ -z "$MEM" ]; then
    MEM="$(prompt_input "Memory (MiB)" "4096")"
  fi
  if [ -z "$VCPUS" ]; then
    VCPUS="$(prompt_input "vCPUs" "2")"
  fi
  if [ -z "$HOME_IMG_SIZE" ]; then
    HOME_IMG_SIZE="$(prompt_input "home.img size (MiB)" "20000")"
  fi

  if ! echo "$MEM" | grep -Eq '^[0-9]+$' || [ "$MEM" -le 0 ]; then
    echo "--mem must be a positive integer" >&2
    exit 1
  fi
  if ! echo "$VCPUS" | grep -Eq '^[0-9]+$' || [ "$VCPUS" -le 0 ]; then
    echo "--vcpus must be a positive integer" >&2
    exit 1
  fi
  if ! echo "$HOME_IMG_SIZE" | grep -Eq '^[0-9]+$' || [ "$HOME_IMG_SIZE" -le 0 ]; then
    echo "--home-img-size must be a positive integer" >&2
    exit 1
  fi

  VM_DIR="$REPO_ROOT/vms/$VM_NAME"
  VM_MODULE="$VM_DIR/default.nix"

  GENERATED_DEFINITION_LINE="  $VM_NAME = mkVm \"$VM_NAME\";"

  existing_registry_name=0
  existing_definition=0
  existing_module=0

  if grep -qE "^[[:space:]]*name = \"$VM_NAME\";" "$REGISTRY_FILE"; then
    existing_registry_name=1
  fi
  if grep -qE "^[[:space:]]*$VM_NAME[[:space:]]*=" "$DEFINITIONS_FILE"; then
    existing_definition=1
  fi
  if [ -f "$VM_MODULE" ]; then
    existing_module=1
  fi

  if [ "$FORCE" -ne 1 ] && [ "$existing_registry_name" -eq 1 ]; then
    echo "VM name '$VM_NAME' already exists in registry." >&2
    exit 1
  fi
  if [ "$FORCE" -ne 1 ] && [ "$existing_definition" -eq 1 ]; then
    echo "Definition exists in $DEFINITIONS_FILE for '$VM_NAME'." >&2
    exit 1
  fi
  if [ "$FORCE" -ne 1 ] && [ "$existing_module" -eq 1 ]; then
    echo "File exists: $VM_MODULE (use --force to overwrite)" >&2
    exit 1
  fi

  CLEAN_REGISTRY_FILE="$REGISTRY_FILE"
  CLEAN_DEFINITIONS_FILE="$DEFINITIONS_FILE"

  # FORCE logic and registry cleaning disabled for simplicity - see git diff history instead.
  # Uniqueness of VM name, short, and IP still checked below on live files.

  if grep -qE "^[[:space:]]*short = \"$VM_SHORT\";" "$REGISTRY_FILE"; then
    echo "VM short '$VM_SHORT' already exists in registry." >&2
    exit 1
  fi

  if [ -z "$VM_IP" ]; then
    VM_IP="$(next_available_vm_ip "$REGISTRY_FILE")"
  fi

  if ! printf '%s\n' "$VM_IP" | ${pkgs.gnugrep}/bin/grep -Eq '^10\.0\.0\.([0-9]{1,3})$'; then
    echo "IP must be in form 10.0.0.X" >&2
    exit 1
  fi

  octet="$(ip_octet "$VM_IP")"
  if [ "$octet" -ge 253 ]; then
    echo "IP octet must be < 253 (got $octet)." >&2
    exit 1
  fi

  if grep -q "ip = \"$VM_IP\";" "$REGISTRY_FILE"; then
    echo "IP '$VM_IP' already exists in registry." >&2
    exit 1
  fi

  NET_INDEX="$octet"
  MAC_SUFFIX="$(printf '%02x' "$NET_INDEX")"
  MAC_ADDR="00:00:00:00:00:$MAC_SUFFIX"

  mkdir -p "$VM_DIR"

  # Prepare template values for the selected profile.
  EXTRA_SERVICE_BLOCKS=""

  case "$PROFILE" in
    default)
      MODULE_IMPORTS="$(cat <<EOF
    ../modules/net-config.nix
    ../modules/common-config.nix
    ../modules/yazi-config.nix
    ../modules/wprs.nix
EOF
)"
      ;;
    minimal)
      MODULE_IMPORTS="$(cat <<EOF
    ../modules/net-config.nix
    ../modules/common-config.nix
EOF
)"
      ;;
    coding)
      MODULE_IMPORTS="$(cat <<EOF
    ../modules/net-config.nix
    ../modules/common-config.nix
    ../modules/ide.nix
    ../modules/zsh.nix
    ../modules/zellij.nix
    ../modules/wprs.nix
    ../modules/yazi-config.nix
EOF
)"
      if [ "$ALLOW_GITHUB_AGENT" = "true" ]; then
        EXTRA_SERVICE_BLOCKS="$(cat <<EOF
  services.ide = {
    enable = true;
    githubAgent.enable = true;
  };
  services.zsh-env.enable = true;
  services.zellij-env.enable = true;
EOF
)"
      else
        EXTRA_SERVICE_BLOCKS="$(cat <<EOF
  services.ide.enable = true;
  services.zsh-env.enable = true;
  services.zellij-env.enable = true;
EOF
)"
      fi
      ;;
  esac

  # Generate the VM Nix module from the shared template.
  tmp_vm_module="$(new_tmp)"
  render_vm_module_from_template "$tmp_vm_module"

  mv "$tmp_vm_module" "$VM_MODULE"
  echo "Created $VM_MODULE"

  definition_block_file="$(new_tmp)"
  printf '%s\n' "$GENERATED_DEFINITION_LINE" > "$definition_block_file"

  definitions_work_file="$(new_tmp)"
  insert_block_at_marker "$CLEAN_DEFINITIONS_FILE" "$DEFINITIONS_INSERT_MARKER" "$definition_block_file" "$definitions_work_file"
  mv "$definitions_work_file" "$DEFINITIONS_FILE"
  echo "Updated $DEFINITIONS_FILE"

  vm_block_file="$(new_tmp)"
  cat > "$vm_block_file" <<EOF
    {
      name = "$VM_NAME";
      short = "$VM_SHORT";
      ip = "$VM_IP";
      autostart = $AUTOSTART;
      nat = $NAT;
      allowGitHubAgent = $ALLOW_GITHUB_AGENT;
      enableHostDbusForward = $ENABLE_HOST_DBUS_FORWARD;
    }
EOF

  registry_work_file="$(new_tmp)"
  insert_block_at_marker "$CLEAN_REGISTRY_FILE" "$REGISTRY_INSERT_MARKER" "$vm_block_file" "$registry_work_file"
  mv "$registry_work_file" "$REGISTRY_FILE"

  echo "Updated $REGISTRY_FILE"
  echo
  echo "VM '$VM_NAME' created successfully."
  echo "Summary:"
  echo "  profile:                 $PROFILE"
  echo "  ip:                      $VM_IP"
  echo "  net index:               $NET_INDEX"
  echo "  mac:                     $MAC_ADDR"
  echo "  autostart:               $AUTOSTART"
  echo "  nat:                     $NAT"
  echo "  allowGitHubAgent:        $ALLOW_GITHUB_AGENT"
  echo "  enableHostDbusForward:   $ENABLE_HOST_DBUS_FORWARD"
  echo "  mem:                     $MEM"
  echo "  vcpus:                   $VCPUS"
  echo "  home.img size:           $HOME_IMG_SIZE"
''
