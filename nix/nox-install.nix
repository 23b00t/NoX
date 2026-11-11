# nox-install: guided installation of a NoX machine from the installer ISO
# (packages.installer-iso). Steps: 1 network (WLAN over nmcli), 2 hardware
# report (nox-hwcheck, paged), 3 clone the config (https first; an SSH key
# only for a private repo or to push a new host), 4 choose the host or add a
# new one (hardware-configuration + nox-hwcheck --nix, commit + push), 5
# partition the disk from nox.disk.device (disko, LUKS passphrase), 6 install
# the minimal system (nox.install: dom0, sys-net, sys-usb, sys-firewall, the
# builders; `nox update` builds the rest after the first boot), 7 the
# Whonix-Gateway image if the config runs it and you want it, 8 the user's
# password. Ctrl-C aborts at any time; nothing is written to the disk before
# step 5 asks for its device name.
#
#   nox-install [--dry-run] [--config URL] [--branch B] [--host H]
#               [--whonix-from DIR]
#
# --dry-run runs steps 1-4 (clone and checks, no commit/push) and only prints
# the commands of steps 5-8. --whonix-from takes the Whonix files from DIR
# (Whonix-CLI-<version>.Intel_AMD64.qcow2.libvirt.xz, its .asc and
# derivative.asc) instead of downloading them.
{
  writeShellApplication,
  coreutils,
  curl,
  disko,
  findutils,
  git,
  gnugrep,
  gnupg,
  gnutar,
  less,
  nixos-install-tools,
  nox-hwcheck,
  openssh,
  qemu-utils,
  util-linux,
  xz,
  # Whonix-Gateway image (README "Whonix"): the version nox-install offers
  # and the key the images are signed with (derivative.asc)
  whonixVersion ? "18.2.1.9",
  whonixFingerprint ? "916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA",
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
    gnupg
    gnutar
    less
    nixos-install-tools
    nox-hwcheck
    openssh
    qemu-utils
    util-linux
    xz
  ];
  text = ''
    dry_run=0
    url=""
    branch=""
    host=""
    whonix_from=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry_run=1 ;;
        --config) url="$2"; shift ;;
        --branch) branch="$2"; shift ;;
        --host) host="$2"; shift ;;
        --whonix-from) whonix_from="$2"; shift ;;
        -h | --help)
          echo "usage: nox-install [--dry-run] [--config URL] [--branch B] [--host H] [--whonix-from DIR]"
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
    editor="''${EDITOR:-nvim}"
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

    # owner/repo of a GitHub URL (SSH or https), else fails
    github_repo() {
      local r
      case "$1" in
        git@github.com:*) r="''${1#git@github.com:}" ;;
        ssh://git@github.com/*) r="''${1#ssh://git@github.com/}" ;;
        https://github.com/*) r="''${1#https://github.com/}" ;;
        *) return 1 ;;
      esac
      r="''${r%.git}"
      [[ "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
      printf '%s' "$r"
    }

    wifi() {
      local ssid
      ssid="$(ask "SSID (empty: back):")"
      [ -n "$ssid" ] || return 0
      if yes_no "Hidden network?"; then
        nmcli --ask device wifi connect "$ssid" hidden yes || true
      else
        nmcli --ask device wifi connect "$ssid" || true
      fi
    }

    # The SSH key for the config (private repo, push of a new host): from
    # the stick or a new one. Its public part goes to GitHub, if you like
    # right here in lynx
    key_ready=0
    setup_key() {
      local from repo page
      [ "$key_ready" = 0 ] || return 0
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
      echo "Public key ($1):"
      cat "$key.pub"
      if repo="$(github_repo "$url")"; then
        echo "Register it at GitHub: as a deploy key of $repo (Settings > Deploy keys; \"Allow write access\" for a new machine) or as a key of your account (Settings > SSH keys)."
        case "$(ask "Open that page in lynx here? d: deploy key, a: account key, Enter: no")" in
          d) page="https://github.com/$repo/settings/keys/new" ;;
          a) page="https://github.com/settings/ssh/new" ;;
          *) page="" ;;
        esac
        if [ -n "$page" ]; then
          cat <<EOF
    In lynx: log in, move to the field "Key", press Ctrl-X i, type
    $key.pub and Enter: lynx inserts the file (there is no copy and paste on
    the console). Or Ctrl-X e: the field opens in $editor (":r $key.pub" in
    nvim). Fill in a title, submit the form, quit lynx with q.
    EOF
          read -rp "Enter: open lynx " _
          lynx "$page" || true
        fi
      fi
      read -rp "Enter when the key is registered " _
      key_ready=1
    }

    step "1/8 Network"
    until curl -sfI --max-time 10 https://github.com >/dev/null; do
      echo "No connection to github.com."
      case "$(ask "w: WLAN, t: nmtui, c: go on without network, Enter: try again")" in
        w) wifi ;;
        t) nmtui || true ;;
        c) break ;;
      esac
    done

    step "2/8 Hardware report (NVIDIA: if the stick hung at boot, start it with the GRUB entry \"nomodeset\")"
    if [ -t 1 ]; then
      NOX_COLOR=1 nox-hwcheck | less -R || true
    else
      nox-hwcheck || true
    fi

    step "3/8 Config"
    [ -n "$url" ] || url="$(ask "Git URL of the config (e.g. https://github.com/<user>/nixos-config):")"
    [ -n "$branch" ] || branch="$(ask "Branch (empty: the default branch):")"
    clone() {
      rm -rf "$dir"
      GIT_TERMINAL_PROMPT=0 git clone ''${branch:+--branch "$branch"} "$1" "$dir"
    }
    # GitHub over https first: a public repo needs no key
    if repo="$(github_repo "$url")" && clone "https://github.com/$repo.git"; then
      echo "Cloned over https."
    else
      case "$url" in
        git@* | ssh://* | https://github.com/*)
          [ -z "$repo" ] || url="git@github.com:$repo.git"
          setup_key "read access to the config"
          ;;
      esac
      until clone "$url"; do
        yes_no "Clone failed. Try again?" || exit 1
      done
    fi

    step "4/8 Host"
    # Machines: the directories under machines/ with a hardware-configuration
    hosts="$(find "$dir/machines" -mindepth 2 -maxdepth 2 -name hardware-configuration.nix -printf '%h\n' | xargs -rn1 basename | sort)"
    echo "Machines in the config: $(tr "\n" " " <<<"$hosts")"
    [ -n "$host" ] || host="$(ask "Host to install (a new name adds a machine):")"
    new_host=0
    if ! grep -qx -- "$host" <<<"$hosts"; then
      new_host=1
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
      (cd "$dir" && "$editor" .)
      git -C "$dir" add -A
      until nix eval --raw "$dir#nixosConfigurations.$host.config.system.name" >/dev/null; do
        yes_no "nixosConfigurations.$host does not evaluate. Edit again?" || exit 1
        (cd "$dir" && "$editor" .)
        git -C "$dir" add -A
      done
      if [ "$dry_run" = 1 ]; then
        echo "dry-run: no commit/push"
      else
        # Unsigned: sign it again later from a machine with the signing key
        # (git commit --amend -S), else the builder doesn't build it
        git -C "$dir" -c user.name=nox-install -c user.email=nox-install@localhost \
          commit --no-gpg-sign -m "$host: new machine (nox-install)"
        # Cloned over https: push over SSH, with a key that may write
        if repo="$(github_repo "$url")"; then
          setup_key "write access to $repo for the new machine"
          git -C "$dir" remote set-url --push origin "git@github.com:$repo.git"
        fi
        until git -C "$dir" push; do
          yes_no "Push failed. Try again?" || break
        done
      fi
    fi
    config="$dir#nixosConfigurations.$host.config"
    user="$(nix eval --raw "$config.nox.user")"

    # Whonix-Gateway: only if the config runs it on this machine
    whonix=0
    if nix eval --json "$dir#nixosConfigurations.$host._module.specialArgs.vmRegistry.imageDomains" \
      --apply 'ds: builtins.any (d: d.name == "whonix-gateway") ds' 2>/dev/null | grep -qx true; then
      echo
      echo "The config runs the Whonix-Gateway here. Nix does not build its image: nox-install"
      echo "can download it now (signed by Whonix, ~2.5 GB) and set it up; else later by hand"
      echo "(README \"Whonix\")."
      if yes_no "Download the Whonix-Gateway image during the installation?"; then
        whonix=1
      fi
    fi
    keep=""
    [ "$whonix" = 0 ] || keep='"whonix-gateway"'
    # The minimal installation (nox.install); `nox update` builds the rest
    minimal="(builtins.getFlake \"git+file://$dir\").nixosConfigurations.\"$host\".noxInstall { keep = [ $keep ]; }"

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
    run disko --mode destroy,format,mount --yes-wipe-all-disks --flake "$dir#$host"

    domains="dom0, sys-net, sys-usb, sys-firewall, the builders"
    [ "$whonix" = 0 ] || domains="$domains, the Whonix-Gateway"
    step "6/8 Install the minimal system ($domains; takes a while)"
    if [ "$dry_run" = 1 ]; then
      echo "dry-run: nix build --store /mnt --impure --expr '($minimal).config.system.build.toplevel'"
      echo "dry-run: nixos-install --system <that> --no-root-passwd --no-channel-copy"
      system=/nix/store/dry-run
    else
      # Built into the new disk's store, as nixos-install --flake does (the
      # live system's store is RAM)
      until system="$(nix build --no-link --print-out-paths --store /mnt \
        --extra-substituters 'auto?trusted=1' --impure \
        --expr "($minimal).config.system.build.toplevel")"; do
        yes_no "Build failed. Try again?" || exit 1
      done
      nixos-install --system "$system" --no-root-passwd --no-channel-copy
    fi

    step "7/8 Whonix-Gateway image"
    if [ "$whonix" = 0 ]; then
      echo "Not wanted or not in the config: skipped."
    else
      image="$(nix eval --raw "$config.services.xen-image-domains.domains.whonix-gateway.image")"
      fpr=${whonixFingerprint}
      if [ -z "$whonix_from" ]; then
        newest="$(curl -fsSL --max-time 20 https://www.whonix.org/download/libvirt/ \
          | grep -oE 'href="[0-9]+(\.[0-9]+)+/' | grep -oE '[0-9]+(\.[0-9]+)+' | sort -V | tail -n 1 || true)"
        [ -z "$newest" ] || echo "Newest version on whonix.org: $newest"
      fi
      v="$(ask "Whonix version (empty: ${whonixVersion}):")"
      [ -n "$v" ] || v=${whonixVersion}
      if ! [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
        echo "not a version: $v" >&2
        exit 1
      fi
      archive="Whonix-CLI-$v.Intel_AMD64.qcow2.libvirt.xz"
      # On the new disk: the live system's /tmp is RAM
      work=/mnt/var/tmp/nox-install-whonix
      if [ "$dry_run" = 1 ]; then
        echo "dry-run: $archive (+ .asc, derivative.asc) to $work, signature by $fpr"
        echo "dry-run: tar -xJf $archive (Gateway), qemu-img convert -O raw -S 4k to /mnt$image"
        echo "dry-run: nixos-enter --root /mnt -c '$system/sw/bin/xen-image-setup whonix-gateway'"
      else
        mkdir -p "$work"
        if [ -n "$whonix_from" ]; then
          cp "$whonix_from/$archive" "$whonix_from/$archive.asc" "$whonix_from/derivative.asc" "$work/"
        else
          base="https://www.whonix.org/download/libvirt/$v"
          until curl -fSL -C - -o "$work/$archive" "$base/$archive"; do
            yes_no "Download failed. Try again (it continues)?" || exit 1
          done
          curl -fsSL -o "$work/$archive.asc" "$base/$archive.asc"
          curl -fsSL -o "$work/derivative.asc" https://www.whonix.org/keys/derivative.asc
        fi
        export GNUPGHOME="$work/gnupg"
        rm -rf "$GNUPGHOME"
        mkdir -m 700 "$GNUPGHOME"
        gpg --batch --quiet --import "$work/derivative.asc"
        if ! gpg --batch --with-colons --fingerprint | grep -q "^fpr:::::::::$fpr:"; then
          echo "derivative.asc does not hold the Whonix key $fpr: stopped, no image." >&2
          exit 1
        fi
        if ! gpg --batch --status-fd 1 --verify "$work/$archive.asc" "$work/$archive" 2>/dev/null \
          | grep -qE "^\[GNUPG:\] VALIDSIG .* $fpr\$"; then
          echo "BAD SIGNATURE on $archive: stopped, no image." >&2
          exit 1
        fi
        echo "Signature good ($fpr)."
        unset GNUPGHOME
        tar -C "$work" -xJf "$work/$archive" --wildcards '*Gateway*'
        mkdir -p "$(dirname "/mnt$image")"
        qemu-img convert -p -O raw -S 4k "$work"/Whonix-Gateway-*.qcow2 "/mnt$image"
        rm -rf "$work"
        # The units into the stopped image (debugfs, works offline)
        nixos-enter --root /mnt -c "$system/sw/bin/xen-image-setup whonix-gateway"
        # An image in the home belongs to the user
        case "$image" in
          "/home/$user/"*) nixos-enter --root /mnt -c "chown -R $user: /home/$user" ;;
        esac
        echo "Whonix-Gateway image: $image. After the first boot enable Tor in it (README \"Whonix\": DisableNetwork 0)."
      fi
    fi

    step "8/8 Password of $user"
    if [ "$dry_run" = 1 ]; then
      echo "dry-run: nixos-enter --root /mnt -c 'passwd $user'"
    else
      until nixos-enter --root /mnt -c "passwd $user"; do :; done
    fi

    echo
    echo "Done: the minimal system is installed. Remove the stick and reboot (reboot);"
    echo "at boot: the LUKS passphrase."
    echo "After the first login \`nox update\` builds and installs the rest (every VM) on"
    echo "the builder. It only builds a HEAD on GitHub that you signed:"
    if [ "$new_host" = 1 ]; then
      echo "sign the commit \"$host: new machine (nox-install)\" first, from a machine with"
      echo "your signing key (git commit --amend -S, then git push --force-with-lease)."
    else
      echo "the branch's last commit must carry your signature."
    fi
  '';
}
