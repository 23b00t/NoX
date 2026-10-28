# nox-install: guided installation of a NoX machine from the installer ISO
# (packages.installer-iso). Steps: 1 network, 2 hardware report (nox-hwcheck),
# 3 clone the config (git URL, SSH key from the stick or a new one), 4 choose
# the host or add a new one (hardware-configuration + nox-hwcheck --nix,
# commit + push), 5 partition the disk from nox.disk.device (disko, LUKS
# passphrase), 6 nixos-install, 7 the user's password, 8 the config clone into
# the user's home. Ctrl-C aborts at any time; nothing is written to the disk
# before step 5 asks for its device name.
#
#   nox-install [--dry-run] [--config URL] [--branch B] [--host H]
#
# --dry-run runs steps 1-4 (clone and checks, no commit/push) and only prints
# the commands of steps 5-8.
{
  writeShellApplication,
  coreutils,
  curl,
  disko,
  findutils,
  git,
  gnugrep,
  nixos-install-tools,
  nox-hwcheck,
  openssh,
  util-linux,
}:
writeShellApplication {
  name = "nox-install";
  runtimeInputs = [
    coreutils
    curl
    disko
    findutils
    git
    gnugrep
    nixos-install-tools
    nox-hwcheck
    openssh
    util-linux
  ];
  text = ''
    dry_run=0
    url=""
    branch=""
    host=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry_run=1 ;;
        --config) url="$2"; shift ;;
        --branch) branch="$2"; shift ;;
        --host) host="$2"; shift ;;
        -h | --help)
          echo "usage: nox-install [--dry-run] [--config URL] [--branch B] [--host H]"
          exit 0
          ;;
        *) echo "nox-install: unknown argument: $1" >&2; exit 2 ;;
      esac
      shift
    done

    if [ "$(id -u)" != 0 ]; then
      echo "nox-install: run as root (sudo nox-install)" >&2
      exit 1
    fi

    trap 'echo; echo "nox-install: aborted" >&2; exit 130' INT

    dir=/tmp/nixos-config
    key=/root/.ssh/id_ed25519
    export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"

    step() {
      echo
      echo "=== $1"
      read -rp "Enter: go on, Ctrl-C: abort " _
    }
    ask() {
      local reply
      read -rp "$1 " reply
      printf '%s' "$reply"
    }
    yes_no() {
      local reply
      read -rp "$1 [y/N] " reply
      [ "$reply" = y ] || [ "$reply" = Y ]
    }
    # Steps 5-8 change the disk: only shown with --dry-run
    run() {
      if [ "$dry_run" = 1 ]; then
        echo "dry-run: $*"
      else
        "$@"
      fi
    }

    step "1/8 Network"
    until curl -sfI --max-time 10 https://github.com >/dev/null; do
      echo "No connection to github.com. WLAN: nmtui (or nmcli device wifi connect <ssid> --ask)."
      if yes_no "Open nmtui?"; then
        nmtui || true
      elif yes_no "Go on without network?"; then
        break
      fi
    done

    step "2/8 Hardware report"
    nox-hwcheck || true

    step "3/8 Config"
    [ -n "$url" ] || url="$(ask "Git URL of the config (e.g. git@github.com:<user>/nixos-config.git):")"
    [ -n "$branch" ] || branch="$(ask "Branch (empty: the default branch):")"
    case "$url" in
      git@* | ssh://*)
        if [ ! -e "$key" ]; then
          install -d -m 700 /root/.ssh
          from="$(ask "SSH key from the stick (path to the private key; empty: create a new one):")"
          if [ -n "$from" ]; then
            install -m 600 "$from" "$key"
            [ ! -e "$from.pub" ] || install -m 644 "$from.pub" "$key.pub"
          else
            ssh-keygen -t ed25519 -N "" -C "nox-install" -f "$key"
          fi
        fi
        [ -e "$key.pub" ] || ssh-keygen -y -f "$key" >"$key.pub"
        echo "Public key (GitHub: Settings > SSH keys, or the repo's deploy keys with write access):"
        cat "$key.pub"
        read -rp "Enter when it is registered " _
        ;;
    esac
    rm -rf "$dir"
    until git clone ''${branch:+--branch "$branch"} "$url" "$dir"; do
      yes_no "Clone failed. Try again?" || exit 1
    done

    step "4/8 Host"
    hosts="$(find "$dir/machines" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)"
    echo "Machines in the config: $(tr "\n" " " <<<"$hosts")"
    [ -n "$host" ] || host="$(ask "Host to install (a new name adds a machine):")"
    if ! grep -qx -- "$host" <<<"$hosts"; then
      echo "New machine $host: machines/$host/hardware-configuration.nix (without file systems) and machines/$host/hwcheck.nix (nox-hwcheck --nix)."
      mkdir -p "$dir/machines/$host"
      nixos-generate-config --no-filesystems --show-hardware-config >"$dir/machines/$host/hardware-configuration.nix"
      nox-hwcheck --nix >"$dir/machines/$host/hwcheck.nix"
      cat <<EOF
    Still to do in the editor:
      - flake.nix: machines.$host (modules, hardware) like the other machines
      - machines/hardware.nix: the block from machines/$host/hwcheck.nix
      - machines/$host: a configuration.nix with nox.disk.device (the disk to install to)
      - vms.nix: the VMs of this machine, if they differ
    EOF
      read -rp "Enter: open the editor " _
      (cd "$dir" && "''${EDITOR:-nvim}" .)
      git -C "$dir" add -A
      until nix eval --raw "$dir#nixosConfigurations.$host.config.system.name" >/dev/null; do
        yes_no "nixosConfigurations.$host does not evaluate. Edit again?" || exit 1
        (cd "$dir" && "''${EDITOR:-nvim}" .)
        git -C "$dir" add -A
      done
      if [ "$dry_run" = 1 ]; then
        echo "dry-run: no commit/push"
      else
        # Unsigned: sign it again later from a machine with the signing key
        # (git commit --amend -S), else the builder doesn't build it
        git -C "$dir" -c user.name=nox-install -c user.email=nox-install@localhost \
          commit --no-gpg-sign -m "$host: new machine (nox-install)"
        until git -C "$dir" push; do
          yes_no "Push failed. Try again?" || break
        done
      fi
    fi
    flake="$dir#$host"
    config="$dir#nixosConfigurations.$host.config"
    user="$(nix eval --raw "$config.nox.user")"

    step "5/8 Disk (erases it)"
    device="$(nix eval --raw "$config.nox.disk.device" 2>/dev/null || true)"
    if [ -z "$device" ]; then
      echo "nixosConfigurations.$host has no nox.disk.device: set it in the config (machines/$host), commit, start again." >&2
      exit 1
    fi
    if [ ! -e "$device" ]; then
      echo "$device not found. Disks here:" >&2
      lsblk -d -o NAME,SIZE,MODEL >&2
      exit 1
    fi
    name="$(basename "$(readlink -f "$device")")"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL "$device"
    until [ "$(ask "Type $name to erase it:")" = "$name" ]; do
      echo "That is not $name (Ctrl-C aborts)."
    done
    echo "disko: GPT, ESP 1 GB, LUKS2 + ext4 (asks the LUKS passphrase)"
    run disko --mode destroy,format,mount --yes-wipe-all-disks --flake "$flake"

    step "6/8 nixos-install (builds the whole machine locally, takes a while)"
    run nixos-install --flake "$flake" --no-root-passwd --no-channel-copy

    step "7/8 Password of $user"
    if [ "$dry_run" = 1 ]; then
      echo "dry-run: nixos-enter --root /mnt -c 'passwd $user'"
    else
      until nixos-enter --root /mnt -c "passwd $user"; do :; done
    fi

    step "8/8 Config into /home/$user/nixos-config"
    run cp -a "$dir" "/mnt/home/$user/nixos-config"
    if [ -e "$key" ] && yes_no "Copy the SSH key ($key) to /home/$user/.ssh too?"; then
      run mkdir -p "/mnt/home/$user/.ssh"
      run cp "$key" "$key.pub" "/mnt/home/$user/.ssh/"
    fi
    run nixos-enter --root /mnt -c "chown -R $user: /home/$user"

    echo
    echo "Done. Remove the stick and reboot (reboot); at boot: the LUKS passphrase."
  '';
}
