# nox-install: guided installation of a NoX machine from the installer ISO
# (packages.installer-iso). Steps: 1 network (the addresses, a connection
# test, WLAN over nmcli, a shell for ip/ping), 2 hardware report
# (nox-hwcheck, paged), 3 the config: clone yours (https first; an SSH key
# only for a private repo or to push) and check that its HEAD carries a
# signature of a key you confirm, or make a new one from the NoX template
# (questions, profiles of VMs), 4 choose the host or add a new one
# (hardware-configuration + nox-hwcheck --nix, the disk to install to), 5 the
# builders' keys (made here, their public parts into the config, one commit
# signed with your key; pushed, and kept on the new disk for the config
# VM), 6 partition the disk (disko, LUKS passphrase), 7 install the minimal
# system (nox.install: dom0, sys-net, sys-usb, sys-firewall, the builders,
# with their keys; `nox update` builds the rest after the first boot), 8 the
# Whonix-Gateway image if the config runs it and you want it, 9 the user's
# password. Ctrl-C aborts at any time; nothing is written to the disk before
# step 6 asks for its device name.
#
#   nox-install [--dry-run] [--config URL] [--branch B] [--host H]
#               [--whonix-from DIR]
#
# --dry-run runs steps 1-5 (clone, checks, keys, no commit/push) and only
# prints the commands of steps 6-9. --config takes a URL or a path (also a
# git bundle). --whonix-from takes the Whonix files from DIR
# (Whonix-CLI-<version>.Intel_AMD64.qcow2.libvirt.xz, its .asc and
# derivative.asc) instead of downloading them.
{
  lib,
  writeShellApplication,
  coreutils,
  curl,
  disko,
  e2fsprogs,
  findutils,
  gawk,
  git,
  gnugrep,
  gnupg,
  gnused,
  gnutar,
  iproute2,
  jq,
  less,
  nix,
  nixos-install-tools,
  nox-hwcheck,
  openssh,
  qemu-utils,
  util-linux,
  xz,
  # The NoX template (template/) for a new config, and the NoX revision this
  # ISO is built from with its inputs ({ nox; inputs.<name>; }, locked
  # entries): a new config's flake.lock pins NoX and NoX's nixpkgs/disko to
  # them (null: a dirty tree, the template's own lock stays)
  template,
  noxLocked ? null,
  # Whonix-Gateway image (README "Whonix"): the fingerprint of the key the
  # images are signed with (Whonix' project signing key, derivative.asc);
  # the version is always the current stable one, asked at install time
  whonixFingerprint ? "916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA",
  # The lowest Whonix version accepted: against a downgrade to an older, still
  # validly signed release announced by whonix.org or a man in the middle.
  # Raised at each NoX release to the then current stable release
  whonixMinVersion ? "18.2.4.3",
}:
let
  noxLockJson = lib.optionalString (noxLocked != null) (builtins.toJSON noxLocked);
in
writeShellApplication {
  name = "nox-install";
  runtimeInputs = [
    coreutils
    curl
    disko
    e2fsprogs
    findutils
    gawk
    git
    gnugrep
    gnupg
    gnused
    gnutar
    iproute2
    jq
    less
    nix
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
    # Keys made here (RAM) until step 7 puts them on the new disk
    keys=/tmp/nox-keys
    editor="''${EDITOR:-nvim}"
    # GitHub's host key (api.github.com/meta), as the builder pins it:
    # checked strictly, never learned on first use
    install -d -m 700 /root/.ssh
    echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" >/root/.ssh/known_hosts_github
    export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts_github"
    # The user's signing key (ssh-ed25519; signs the installer's commit) and
    # where the config goes: github (push), local (only on the new disk, for
    # the config VM), mirror (both)
    sign_key=""
    new_config=0
    remote=github

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
    # ask with a default shown in brackets
    ask_default() {
      local reply
      read -rp "$1 [$2] " reply
      printf '%s' "''${reply:-$2}"
    }
    yes_no() {
      local reply
      read -rp "$1 [y/N] " reply
      [ "$reply" = y ] || [ "$reply" = Y ]
    }
    # Steps 6-9 change the disk: only shown with --dry-run
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

    # Offers to open a GitHub key page in lynx (no copy and paste on the
    # console: lynx inserts the file into the form)
    github_page() {
      local page=$1 file=$2
      cat <<EOF
    In lynx: log in, move to the field "Key", press Ctrl-X i, type
    $file and Enter: lynx inserts the file (there is no copy and paste on
    the console). Or Ctrl-X e: the field opens in $editor (":r $file" in
    nvim). Fill in a title, submit the form, quit lynx with q.
    EOF
      read -rp "Enter: open lynx " _
      lynx "$page" || true
    }

    # The SSH key for the config (private repo, push): from the stick or a
    # new one. Its public part goes to GitHub, if you like right here in lynx
    key_ready=0
    setup_key() {
      local from repo
      [ "$key_ready" = 0 ] || return 0
      if [ ! -e "$key" ]; then
        from="$(ask "SSH key from the stick (path to the private key; empty: create a new one):")"
        if [ -n "$from" ]; then
          install -m 600 "$from" "$key"
          [ ! -e "$from.pub" ] || install -m 644 "$from.pub" "$key.pub"
        else
          ssh-keygen -q -t ed25519 -N "" -C "nox-install" -f "$key"
        fi
      fi
      [ -e "$key.pub" ] || ssh-keygen -y -f "$key" >"$key.pub"
      echo "Public key ($1):"
      cat "$key.pub"
      if repo="$(github_repo "$url")"; then
        echo "Register it at GitHub as a deploy key of $repo (Settings > Deploy keys; \"Allow write access\" to push). A deploy key, not an account key: it opens this one repo only. Delete it there after the installation."
        if yes_no "Open that page in lynx here?"; then
          github_page "https://github.com/$repo/settings/keys/new" "$key.pub"
        fi
      fi
      read -rp "Enter when the key is registered " _
      key_ready=1
    }

    # A shell to look at the network (ip a, ping, nmcli); exit returns
    net_shell() {
      echo "Shell: e.g. ip a, ping -c 3 1.1.1.1, nmcli device; exit: back to nox-install"
      bash -i || true
    }

    # The public key of a key line (allowed-signers: [principal] [options]
    # <type> <base64> [comment]), as "<type> <base64>"
    pubkey_of() {
      awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $i, $(i + 1); exit } }' <<<"$1"
    }

    # The user's signing key (ssh-ed25519): signs the installer's commit,
    # which the builder only builds when it is signed by a key in
    # allowed-signers. From the stick, or (new config) a new one
    setup_sign_key() {
      local from
      [ -z "$sign_key" ] || return 0
      install -d -m 700 "$keys"
      if [ "$new_config" = 1 ]; then
        from="$(ask "Your signing key from the stick (path to the private key; empty: create a new one):")"
      else
        from="$(ask "Your signing key from the stick (path to the private key; empty: commit unsigned, sign it later):")"
      fi
      if [ -n "$from" ]; then
        install -m 600 "$from" "$keys/signing-key"
        ssh-keygen -y -f "$keys/signing-key" >"$keys/signing-key.pub"
        if [ "$new_config" = 0 ] && ! grep -qF "$(pubkey_of "$(cat "$keys/signing-key.pub")")" "$dir/$keyrel/allowed-signers"; then
          echo "That key is not in $keyrel/allowed-signers: the builder would not build the commit. Committing unsigned."
          rm -f "$keys/signing-key" "$keys/signing-key.pub"
          return 0
        fi
      elif [ "$new_config" = 1 ]; then
        ssh-keygen -q -t ed25519 -N "" -C "nox-config" -f "$keys/signing-key"
        echo "New signing key; the config VM gets it (back it up: nox backup)."
      else
        return 0
      fi
      sign_key="$keys/signing-key"
    }

    # Commit everything in the config, signed with the user's key if there
    # is one
    commit_config() {
      local msg=$1
      git -C "$dir" add -A
      if [ -n "$sign_key" ]; then
        git -C "$dir" -c user.name="''${sign_name:-nox-install}" -c user.email="''${sign_email:-nox-install@localhost}" \
          -c gpg.format=ssh -c user.signingkey="$sign_key" -c gpg.ssh.program=ssh-keygen \
          commit --quiet -S -m "$msg"
      else
        git -C "$dir" -c user.name=nox-install -c user.email=nox-install@localhost \
          commit --quiet --no-gpg-sign -m "$msg"
      fi
    }

    step "1/9 Network"
    # A LAN (or a WLAN from earlier) may be up already: then no WLAN setup
    while :; do
      ip -brief address || true
      if curl -sfI --max-time 10 https://github.com >/dev/null; then
        echo "Connected: github.com answers."
        case "$(ask "Enter: go on, s: shell")" in
          s) net_shell ;;
          *) break ;;
        esac
      else
        echo "No connection to github.com."
        case "$(ask "w: WLAN, t: nmtui, s: shell, c: go on without network, Enter: try again")" in
          w) wifi ;;
          t) nmtui || true ;;
          s) net_shell ;;
          c) break ;;
        esac
      fi
    done

    step "2/9 Hardware report (NVIDIA: if the stick hung at boot, start it with the GRUB entry \"nomodeset\")"
    if [ -t 1 ]; then
      NOX_COLOR=1 nox-hwcheck | less -R || true
    else
      nox-hwcheck || true
    fi

    step "3/9 Config"
    if [ -z "$url" ]; then
      echo "The Git URL of your config (or a path, e.g. a git bundle on the stick)."
      echo "Empty: a new config from the NoX template."
      url="$(ask "Git URL (e.g. https://github.com/<user>/nixos-config):")"
    fi

    # The keys whose signatures the config accepts: the directory with
    # allowed-signers (the config's `builderKeys`), relative to the repo
    keyrel=""
    find_keyrel() {
      local f
      f="$(git -C "$dir" ls-files -- '*allowed-signers' | head -n 1)"
      [ -n "$f" ] || return 1
      keyrel="$(dirname "$f")"
    }

    if [ -z "$url" ]; then
      # ---- A new config (template) ----
      new_config=1
      rm -rf "$dir"
      cp -r --no-preserve=mode,ownership ${template}/. "$dir"
      keyrel=vms/builder
      ${lib.optionalString (noxLocked != null) ''
        # NoX and its inputs (the config's nixpkgs follows NoX's) as this
        # ISO: their sources are in the ISO's store already
        jq --argjson n ${lib.escapeShellArg noxLockJson} '
          .nodes.nox.locked = $n.nox
          | reduce ($n.inputs | keys[]) as $k (.;
              .nodes[.nodes.nox.inputs[$k]].locked = $n.inputs[$k])' \
          "$dir/flake.lock" >"$dir/flake.lock.new"
        mv "$dir/flake.lock.new" "$dir/flake.lock"
      ''}
      echo
      echo "Where the config lives:"
      echo "  l: only on this machine, in the config VM (no account needed; back it up with nox backup)"
      echo "  g: on GitHub (a repo you created, empty), the builder fetches it from there"
      echo "  m: both: in the config VM, mirrored to GitHub"
      case "$(ask_default "l, g or m?" l)" in
        g) remote=github ;;
        m) remote=mirror ;;
        *) remote=local ;;
      esac
      repo_url=""
      if [ "$remote" != local ]; then
        until repo="$(github_repo "$(ask "GitHub URL of the (empty) repo, e.g. https://github.com/<user>/nixos-config:")")"; do
          echo "Not a GitHub repo URL."
        done
        url="git@github.com:$repo.git"
        # A public repo: the builder fetches over https without a key
        if yes_no "Is the repo public?"; then
          repo_url="https://github.com/$repo"
        else
          repo_url="$url"
        fi
      fi
      git -C "$dir" init --quiet
      sign_name="$(ask_default "Your name (for the commits):" "nox")"
      sign_email="$(ask_default "Your email (for the commits and allowed-signers):" "nox@localhost")"
      setup_sign_key
      printf '%s namespaces="git" %s\n' "$sign_email" "$(pubkey_of "$(cat "$keys/signing-key.pub")")" \
        >>"$dir/$keyrel/allowed-signers"
    else
      # ---- An existing config ----
      [ -n "$branch" ] || branch="$(ask "Branch (empty: the default branch):")"
      clone() {
        rm -rf "$dir"
        GIT_TERMINAL_PROMPT=0 git clone --quiet ''${branch:+--branch "$branch"} "$1" "$dir"
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
      case "$url" in
        git@* | ssh://* | https://*) remote=github ;;
        *) remote=local ;;
      esac

      # Nothing of the clone runs (no evaluation, disko, nixos-install) before
      # its HEAD is checked: signed by a key of its allowed-signers that you
      # confirm, or a builder's flake.lock bump on top of such a commit (as
      # the builder checks it, vms/builder)
      if ! find_keyrel; then
        echo "The config has no allowed-signers (builderKeys): its HEAD cannot be checked. Stopped." >&2
        exit 1
      fi
      echo
      echo "Keys allowed to sign this config ($keyrel/allowed-signers):"
      n=0
      while read -r line; do
        case "$line" in "" | "#"*) continue ;; esac
        k="$(pubkey_of "$line")"
        [ -n "$k" ] || continue
        echo "  $(awk '{ print $1 }' <<<"$line")  $(ssh-keygen -l -f /dev/stdin <<<"$k" | awk '{ print $2, $NF }')"
        n=$((n + 1))
      done <"$dir/$keyrel/allowed-signers"
      if [ "$n" = 0 ]; then
        echo "No key in $keyrel/allowed-signers: its HEAD cannot be checked. Stopped." >&2
        exit 1
      fi
      echo "Compare the fingerprints with your key (ssh-keygen -lf <key>.pub on your machine)."
      yes_no "Are these your keys?" || { echo "Stopped." >&2; exit 1; }
      signed_by() {
        git -C "$dir" -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile="$2" \
          verify-commit "$1" >/dev/null 2>&1
      }
      trusted() {
        local c=$1 _
        for _ in $(seq 50); do
          signed_by "$c" "$dir/$keyrel/allowed-signers" && return 0
          [ -e "$dir/$keyrel/bump-signers" ] || return 1
          signed_by "$c" "$dir/$keyrel/bump-signers" || return 1
          [ "$(git -C "$dir" rev-list --no-walk --parents "$c" | wc -w)" = 2 ] || return 1
          [ "$(git -C "$dir" diff --name-only "$c^" "$c")" = flake.lock ] || return 1
          c="$(git -C "$dir" rev-parse "$c^")"
        done
        return 1
      }
      if ! trusted HEAD; then
        echo "HEAD ($(git -C "$dir" rev-parse --short HEAD)) is not signed by one of these keys: stopped." >&2
        echo "Sign it on your machine (git commit --amend -S, push) and start again." >&2
        exit 1
      fi
      echo "HEAD $(git -C "$dir" rev-parse --short HEAD) is signed by one of your keys."
      branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    fi

    step "4/9 Host"
    hosts="$(find "$dir/machines" -mindepth 2 -maxdepth 2 -name hardware-configuration.nix -printf '%h\n' | xargs -rn1 basename | sort)"
    if [ "$new_config" = 1 ]; then
      hosts=""
      [ -n "$host" ] || host="$(ask_default "Name of this machine (host name):" nox)"
    else
      echo "Machines in the config: $(tr "\n" " " <<<"$hosts")"
      [ -n "$host" ] || host="$(ask "Host to install (a new name adds a machine):")"
    fi
    until [[ "$host" =~ ^[a-z][a-z0-9-]*$ ]]; do
      host="$(ask "Host names: lowercase letters, digits, -. Name:")"
    done
    new_host=0
    mdir="$dir/machines/$host"
    if ! grep -qx -- "$host" <<<"$hosts"; then
      new_host=1
      # Template layout: machines/<host>/{configuration,hardware}.nix, found
      # by flake.nix itself (readDir); else the old one (edit flake.nix)
      if [ "$new_config" = 1 ] || compgen -G "$dir/machines/*/hardware.nix" >/dev/null; then
        layout=dirs
      else
        layout=flake
      fi
      mkdir -p "$mdir"
      nixos-generate-config --no-filesystems --show-hardware-config >"$mdir/hardware-configuration.nix"
      if [ "$layout" = dirs ]; then
        nox-hwcheck --nix >"$mdir/hardware.nix"
      else
        nox-hwcheck --nix >"$mdir/hwcheck.nix"
      fi
    fi

    if [ "$new_config" = 1 ]; then
      # ---- The new config's machine and VMs ----
      # The branch is the machine's name (dom0-update fetches that one)
      branch="$host"
      git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
      # The template's machine "nox" gave the layout; this one is $host
      [ "$host" = nox ] || rm -rf "$dir/machines/nox"
      user="$(ask_default "Your user name on this machine:" user)"
      until [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; do
        user="$(ask "User names: lowercase letters, digits, _ and -. Name:")"
      done
      echo "Editor of the config VM: nano, helix, nvim (terminal); kate, gnome-text-editor, vscodium, zed (windows)"
      cfg_editor="$(ask_default "Editor:" nano)"
      until [[ " nano helix nvim kate gnome-text-editor vscodium zed " == *" $cfg_editor "* ]]; do
        cfg_editor="$(ask "One of nano, helix, nvim, kate, gnome-text-editor, vscodium, zed:")"
      done
      layout_kb="$(ask_default "Keyboard layout (us, de, fr, …):" us)"
      tz="$(ask_default "Time zone:" "Europe/Berlin")"
      cat >"$mdir/configuration.nix" <<EOF
    # $host: Xen dom0, user, locale, keyboard (nox-install). Everything else of
    # dom0 comes from NoX (dom0 base, desktop, tools); the hardware from
    # hardware-configuration.nix and hardware.nix, the disk from disk.nix
    { inputs, ... }:
    {
      imports = [
        ./hardware-configuration.nix
        inputs.nox.nixosModules.xen-dom0
      ];

      networking.hostName = "$host";
      nox.user = "$user";

      time.timeZone = "$tz";
      i18n.defaultLocale = "en_US.UTF-8";
      console.keyMap = "$layout_kb";
      services.xserver.xkb.layout = "$layout_kb";

      system.stateVersion = "26.05";
    }
    EOF

      # The VMs: profiles, each one or more entries of vms.nix (NoX roles and
      # the app catalog). sys-net, sys-usb, sys-firewall, disp and the
      # builder are always there
      gpu=0
      grep -q '^ *gpu = \[' "$mdir/hardware.nix" && gpu=1
      # cpuPool of the gaming VM: the P-cores of a hybrid CPU (Intel:
      # cpu_core/cpu_atom), else the upper half; dom0 and the other VMs keep
      # the rest (at least 2 CPUs). Empty with fewer than 4 CPUs
      pool_cpus() {
        local n p
        n="$(nproc --all)"
        [ "$n" -ge 4 ] || return 0
        if [ -r /sys/devices/cpu_core/cpus ] && [ -r /sys/devices/cpu_atom/cpus ]; then
          p="$(tr ',' '\n' </sys/devices/cpu_core/cpus | while IFS=- read -r a b; do seq "$a" "''${b:-$a}"; done)"
          if [ $((n - $(wc -l <<<"$p"))) -ge 2 ]; then
            paste -sd " " <<<"$p"
            return 0
          fi
        fi
        seq $((n / 2)) $((n - 1)) | paste -sd " "
      }
      echo
      echo "The VMs (profiles); more later in vms.nix:"
      echo "  1 browser   net: Firefox (untrusted)"
      echo "  2 vault     passwords: KeePassXC, no network"
      echo "  3 office    LibreOffice, PDF tools, no network"
      echo "  4 chat      Element, Telegram"
      echo "  5 media     GIMP, Inkscape, VLC"
      echo "  6 dev       software development: editor, git, zsh, zellij"
      echo "  7 windows   Windows programs (Bottles)"
      echo "  8 tor       Whonix-Gateway and -Workstation (Tor Browser)"
      echo "  9 printing  sys-print: printers in the local network"
      if [ "$gpu" = 1 ]; then
        echo " 10 gaming    Steam with the second GPU passed through (proprietary)"
      fi
      picks=" $(ask_default "Numbers, separated by spaces:" "1 2 3 4 6") "
      index=3
      vm() {
        # vm <name> <short> <label> <role> [extra lines…]
        local name=$1 short=$2 label=$3 role=$4
        shift 4
        echo "      $name = {"
        echo "        role = \"$role\";"
        echo "        index = $index;"
        echo "        short = \"$short\";"
        echo "        label = \"$label\";"
        for l in "$@"; do echo "        $l"; done
        echo "      };"
        index=$((index + 1))
      }
      picked() { [[ "$picks" == *" $1 "* ]]; }
      {
        echo "# The domains of this config (nox-install; schema: NoX"
        echo "# nixos/registry/vms.nix, docs in NoX docs/options.md). A VM is one entry:"
        echo "# its role, trust label, apps and resources. sys-net, sys-usb and"
        echo "# sys-firewall come with NoX."
        echo "_: {"
        echo "  nox = {"
        echo "    infra = {"
        echo "      disp.enable = true;"
        echo "      # builds and signs dom0's system (nox update, nox rebuild)"
        echo "      builder.enable = true;"
        picked 9 && echo "      sys-print.enable = true;"
        echo "    };"
        echo "    vms = {"
        if [ "$remote" = local ]; then
          echo "      # the builder gets the config from the config VM (through dom0)"
          echo "      builder.module.nox.builder.source = \"local\";"
        else
          echo "      # the repo the builder builds"
          echo "      builder.module.nox.builder.repoUrl = \"$repo_url\";"
        fi
        # The config VM: the repo, your signing key, an editor; without a
        # remote it needs no network, with GitHub it pushes through dom0's
        # GitHub agent
        if [ "$remote" = local ]; then
          vm config cfg config config "uplink = null;" "module = ./vms/config.nix;"
        else
          vm config cfg config config "module = ./vms/config.nix;" "githubAgent = true;"
        fi
        picked 1 && vm net n untrusted browser "apps.firefox = { };"
        picked 2 && vm vault v vault desktop "uplink = null;" "clipboard = \"deny\";" "apps.keepassxc = { };"
        picked 3 && vm office o personal desktop "uplink = null;" "apps.libreoffice = { };" "apps.pdfarranger = { };"
        picked 4 && vm chat c social desktop "apps.element = { };" "apps.telegram = { };"
        picked 5 && vm media m personal desktop "apps.gimp = { };" "apps.inkscape = { };" "apps.vlc = { };"
        picked 6 && vm dev dv dev dev
        picked 7 && vm win w untrusted windows "apps.bottles = { };"
        if [ "$gpu" = 1 ] && picked 10; then
          pool="$(pool_cpus)"
          if [ -n "$pool" ]; then
            vm steam s untrusted gaming "storeGroup = null;" "module = ./vms/steam.nix;" \
              "# its own CPUs while it runs (check: xl info -n)" "cpuPool = [ $pool ];"
          else
            vm steam s untrusted gaming "storeGroup = null;" "module = ./vms/steam.nix;"
          fi
        fi
        echo "    };"
        if picked 8; then
          echo "    # Whonix from the upstream images (nox-install downloads the Gateway)"
          echo "    images = {"
          echo "      whonix-gateway = {"
          echo "        index = 27;"
          echo "        short = \"wg\";"
          echo "        label = \"anon\";"
          echo "      };"
          echo "      whonix-workstation = {"
          echo "        index = 28;"
          echo "        short = \"ww\";"
          echo "        label = \"anon\";"
          echo "        apps.torbrowser.name = \"Tor Browser\";"
          echo "      };"
          echo "    };"
        fi
        echo "  };"
        echo "}"
      } >"$dir/vms.nix"
      mkdir -p "$dir/vms"
      cat >"$dir/vms/config.nix" <<EOF
    # config: the config repo (~/config), your signing key, the editor
    # (nox-config edit; NoX roles/config.nix)
    {
      nox.configVm.editor = "$cfg_editor";
    }
    EOF
      if [ "$gpu" = 1 ] && picked 10; then
        mkdir -p "$dir/vms"
        cat >"$dir/vms/steam.nix" <<'EOF'
    # steam: NoX role gaming (Steam in a gamescope session, proprietary,
    # allowed by name only) with the second GPU passed through; keyboard
    # and gamepads over USB/IP from sys-usb (`nox usb attach <device> steam`).
    # The GPU driver goes here: NoX README "Gaming" (NVIDIA: the example
    # there)
    { }
    EOF
      fi
    elif [ "$new_host" = 1 ]; then
      if [ "$layout" = dirs ]; then
        # The configuration of another machine as the start
        other="$(head -n 1 <<<"$hosts")"
        if [ -n "$other" ] && [ -e "$dir/machines/$other/configuration.nix" ]; then
          sed "s/networking.hostName = \"$other\"/networking.hostName = \"$host\"/" \
            "$dir/machines/$other/configuration.nix" >"$mdir/configuration.nix"
        fi
        cat <<EOF
    New machine $host: machines/$host/hardware-configuration.nix (without file
    systems), hardware.nix (nox-hwcheck --nix)$([ -n "''${other:-}" ] && echo " and configuration.nix (from $other)").
    Still to do in the editor: machines/$host/configuration.nix, vms.nix (the
    VMs of this machine, if they differ).
    EOF
      else
        cat <<EOF
    New machine $host: machines/$host/hardware-configuration.nix (without file
    systems) and machines/$host/hwcheck.nix (nox-hwcheck --nix).
    Still to do in the editor:
      - flake.nix: machines.$host (modules, hardware) like the other machines
      - machines/hardware.nix: the block from machines/$host/hwcheck.nix
      - machines/$host: a configuration.nix (nox.disk.device: the disk, or
        disk.nix from the next question, imported there)
      - vms.nix: the VMs of this machine, if they differ
    EOF
      fi
      read -rp "Enter: open the editor " _
      (cd "$dir" && "$editor" .)
    fi

    git -C "$dir" add -A
    config="$dir#nixosConfigurations.$host.config"
    until nix eval --raw "$config.system.name" >/dev/null; do
      yes_no "nixosConfigurations.$host does not evaluate. Edit again?" || exit 1
      (cd "$dir" && "$editor" .)
      git -C "$dir" add -A
    done
    if [ "$(nix eval --raw "$config.networking.hostName")" != "$host" ]; then
      echo "networking.hostName of $host is \"$(nix eval --raw "$config.networking.hostName")\": the builder's keys are named after the host, set it to \"$host\". Stopped." >&2
      exit 1
    fi

    # The disk: nox.disk.device, else chosen here and written to
    # machines/<host>/disk.nix (the template's flake.nix imports it)
    device="$(nix eval --raw "$config.nox.disk.device" 2>/dev/null || true)"
    while [ -z "$device" ]; do
      echo
      echo "nixosConfigurations.$host has no nox.disk.device (the disk to install to). Disks here:"
      lsblk -d -e 7,11 -o NAME,SIZE,MODEL,SERIAL
      d="$(ask "Disk (NAME, e.g. nvme0n1):")"
      [ -b "/dev/$d" ] || { echo "/dev/$d is no disk."; continue; }
      id="$(find /dev/disk/by-id -lname "*/$d" ! -name 'nvme-eui.*' ! -name 'wwn-*' -printf '%p\n' | sort | head -n 1)"
      [ -n "$id" ] || id="/dev/$d"
      cat >"$mdir/disk.nix" <<EOF
    # The disk nox-install installed $host to (GPT, ESP, LUKS2 + ext4)
    {
      nox.disk.device = "$id";
    }
    EOF
      git -C "$dir" add -A
      device="$(nix eval --raw "$config.nox.disk.device" 2>/dev/null || true)"
      if [ -z "$device" ]; then
        echo "machines/$host/disk.nix is not imported: add it to the imports of machines/$host/configuration.nix."
        read -rp "Enter: open the editor " _
        (cd "$dir" && "$editor" "$mdir/configuration.nix")
        git -C "$dir" add -A
        device="$(nix eval --raw "$config.nox.disk.device" 2>/dev/null || true)"
      fi
    done
    user="$(nix eval --raw "$config.nox.user")"

    step "5/9 Keys of the builders"
    # The builder VMs of this machine get their keys here (RAM) instead of
    # at their first boot: dom0 trusts the builder from the first boot on
    # (signing-key-<host>.pub), logs in with its own key (ssh-key-<vm>-<host>.pub,
    # private part in ~/.ssh/<vm>-vm), the image keys sign the store image
    # manifests, the bump key signs and pushes flake.lock (nox update)
    registry="$dir#nixosConfigurations.$host._module.specialArgs.vmRegistry"
    builders="$(nix eval --raw "$registry.vms" --apply 'vs: builtins.concatStringsSep " " (map (v: v.name) (builtins.filter (v: v.name == "builder" || builtins.substring 0 8 v.name == "builder-") vs))')"
    if [ -z "$builders" ]; then
      echo "No builder on $host: dom0 builds itself (no keys)."
    else
      [ -n "$keyrel" ] || find_keyrel || keyrel=vms/builder
      kdir="$dir/$keyrel"
      mkdir -p "$kdir"
      install -d -m 700 "$keys"
      for b in $builders; do
        s="$keys/$b/state"
        rm -rf "''${keys:?}/$b"
        mkdir -p "$s"
        ssh-keygen -q -t ed25519 -N "" -C "$b-vm" -f "$keys/$b/login"
        if [ "$b" = builder ]; then
          nix --extra-experimental-features nix-command key generate-secret --key-name builder-vm-1 >"$s/signing-key"
          nix --extra-experimental-features nix-command key convert-secret-to-public <"$s/signing-key" >"$s/signing-key.pub"
          for k in deploy bump image; do
            ssh-keygen -q -t ed25519 -N "" -C "builder-vm-$k" -f "$s/$k-key"
          done
          cp "$s/signing-key.pub" "$kdir/signing-key-$host.pub"
          cp "$s/image-key.pub" "$kdir/image-key-$host.pub"
          # bump-signers: one line per machine
          touch "$kdir/bump-signers"
          grep -v "^builder-$host " "$kdir/bump-signers" >"$kdir/bump-signers.new" || true
          printf 'builder-%s namespaces="git" %s\n' "$host" "$(pubkey_of "$(cat "$s/bump-key.pub")")" >>"$kdir/bump-signers.new"
          mv "$kdir/bump-signers.new" "$kdir/bump-signers"
        else
          ssh-keygen -q -t ed25519 -N "" -C "$b-image" -f "$s/image-key"
          cp "$s/image-key.pub" "$kdir/image-key-$b-$host.pub"
        fi
        cp "$keys/$b/login.pub" "$kdir/ssh-key-$b-$host.pub"
        # In the VM they belong to its user (uid 1000, group users)
        chmod 644 "$s"/*.pub
        find "$s" -type f ! -name '*.pub' -exec chmod 600 {} +
        chown -R 1000:100 "$s"
      done
      git -C "$dir" add -A
      # vms.nix may still set hostSSHKey of a builder: that one wins over the file
      for b in $builders; do
        until [ "$(nix eval --raw "$registry.byName.\"$b\".hostSSHKey" 2>/dev/null || true)" = "$(cat "$keys/$b/login.pub")" ]; do
          echo "vms.nix sets hostSSHKey of $b: delete that line, the new key in $keyrel/ssh-key-$b-$host.pub takes over."
          read -rp "Enter: open the editor " _
          (cd "$dir" && "$editor" vms.nix)
          git -C "$dir" add -A
        done
      done
      echo "Keys made for: $builders"
    fi

    # One commit with the new machine and the keys, signed with your key
    if [ "$new_config" = 0 ]; then
      setup_sign_key
    fi
    if [ "$new_config" = 1 ]; then
      msg="$host: new config (nox-install)"
    elif [ "$new_host" = 1 ]; then
      msg="$host: new machine (nox-install)"
    else
      msg="$host: builder keys (nox-install)"
    fi
    if [ "$dry_run" = 1 ]; then
      echo "dry-run: commit \"$msg\" ($([ -n "$sign_key" ] && echo signed || echo unsigned)), no push"
    elif [ "$new_config" = 0 ] && [ -z "$builders" ] && [ "$new_host" = 0 ] && git -C "$dir" diff --cached --quiet; then
      echo "Nothing changed in the config."
    else
      commit_config "$msg"
      echo "Committed: $msg"
      if [ "$remote" = github ] || [ "$remote" = mirror ]; then
        # Cloned over https: push over SSH, with a key that may write
        if repo="$(github_repo "$url")"; then
          setup_key "write access to $repo"
          git -C "$dir" remote remove origin 2>/dev/null || true
          git -C "$dir" remote add origin "git@github.com:$repo.git"
        fi
        until git -C "$dir" push --quiet origin "HEAD:refs/heads/$branch"; do
          if ! yes_no "Push failed. Try again?"; then
            echo "Not pushed: the commit is kept on the new disk (/var/lib/nox/seed, the config VM gets it); push it from there."
            break
          fi
        done
      fi
    fi
    # A new local config needs no GitHub keys (the builder gets it through dom0)
    if [ -n "$builders" ] && { [ "$new_config" = 0 ] || [ "$remote" != local ]; }; then
      echo
      echo "The builder's GitHub keys (register them as deploy keys of the config repo):"
      echo "  read (a private repo): $(cat "$keys/builder/state/deploy-key.pub" 2>/dev/null)"
      echo "  write (nox update pushes flake.lock): $(cat "$keys/builder/state/bump-key.pub" 2>/dev/null)"
      if [ "$remote" != local ] && repo="$(github_repo "$url")" && yes_no "Open GitHub's deploy key page in lynx now?"; then
        github_page "https://github.com/$repo/settings/keys/new" "$keys/builder/state/deploy-key.pub"
        github_page "https://github.com/$repo/settings/keys/new" "$keys/builder/state/bump-key.pub"
      fi
    fi

    whonix=0
    if nix eval --json "$registry.imageDomains" \
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

    step "6/9 Disk (erases it)"
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
    step "7/9 Install the minimal system ($domains; takes a while)"
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

    # The builders' keys onto the new disk: the state volume (builder.img,
    # its size from the VM's microvm.volumes; microvm.nix creates a volume
    # only when it is missing) and dom0's login keys
    if [ -n "$builders" ]; then
      blist=""
      for b in $builders; do blist="$blist \"$b\""; done
      sizes="$(nix eval --raw --impure --expr "let c = ($minimal).config; size = b: (builtins.head (builtins.filter (v: v.image == \"builder.img\") (builtins.getAttr b c.microvm.vms).config.config.microvm.volumes)).size; in builtins.concatStringsSep \" \" (map (b: b + \"=\" + toString (size b)) [ $blist ])")"
      for bs in $sizes; do
        b="''${bs%%=*}"
        mb="''${bs#*=}"
        img="/mnt/var/lib/microvms/$b/builder.img"
        if [ "$dry_run" = 1 ]; then
          echo "dry-run: $img ($mb MB, ext4 with the keys of $b), /mnt/home/$user/.ssh/$b-vm"
          continue
        fi
        install -d "/mnt/var/lib/microvms/$b"
        rm -f "$img"
        touch "$img"
        chattr +C "$img" 2>/dev/null || true
        truncate -s "''${mb}M" "$img"
        mkfs.ext4 -q -d "$keys/$b/state" "$img"
        install -d -m 700 "/mnt/home/$user/.ssh"
        install -m 600 "$keys/$b/login" "/mnt/home/$user/.ssh/$b-vm"
        install -m 644 "$keys/$b/login.pub" "/mnt/home/$user/.ssh/$b-vm.pub"
      done
      [ "$dry_run" = 1 ] || nixos-enter --root /mnt -c "chown -R $user: /home/$user/.ssh"
    fi
    # The config (and the signing key) for the config VM: it fetches them at
    # the first login (dom0: nox-config-seed); kept also when the push failed
    if [ "$dry_run" = 1 ]; then
      echo "dry-run: git bundle of the config to /mnt/var/lib/nox/seed"
    else
      install -d -m 700 /mnt/var/lib/nox/seed
      git -C "$dir" bundle create --quiet /mnt/var/lib/nox/seed/config.bundle --all
      [ -z "$sign_key" ] || [ "$new_config" = 0 ] || install -m 600 "$sign_key" /mnt/var/lib/nox/seed/signing-key
      [ "$remote" = local ] || [ -z "$url" ] || printf '%s\n' "$url" >/mnt/var/lib/nox/seed/remote
      nixos-enter --root /mnt -c "chown -R $user: /var/lib/nox/seed"
    fi

    step "8/9 Whonix-Gateway image"
    if [ "$whonix" = 0 ]; then
      echo "Not wanted or not in the config: skipped."
    else
      # Any failure skips Whonix and goes on to the password: every command
      # is checked by hand (set -e is off in a function called from an if)
      image="" work="" reason=""
      whonix_install() {
        local fpr v f archive base
        image="$(nix eval --raw "$config.services.xen-image-domains.domains.whonix-gateway.image")" \
          || { reason="cannot evaluate the image path"; return 1; }
        fpr=${whonixFingerprint}
        v=""
        if [ -n "$whonix_from" ]; then
          # The version of the archive in DIR
          for f in "$whonix_from"/Whonix-CLI-*.Intel_AMD64.qcow2.libvirt.xz; do
            v="''${f##*/Whonix-CLI-}"
            v="''${v%.Intel_AMD64.qcow2.libvirt.xz}"
          done
          echo "Whonix version: $v (from $whonix_from)"
        else
          # Always the current stable release: the version whonix.org's KVM
          # page downloads (wiki template Version_KVM; the directory listing
          # also holds testers-only versions)
          until v="$(curl -fsSL --max-time 20 \
            'https://www.whonix.org/w/api.php?action=expandtemplates&text=%7B%7BVersion_KVM%7D%7D&prop=wikitext&format=json' \
            | grep -oE '"wikitext":"[0-9]+(\.[0-9]+)+"' | grep -oE '[0-9]+(\.[0-9]+)+')"; do
            yes_no "No stable version from whonix.org. Try again?" \
              || { reason="no stable version from whonix.org"; return 1; }
          done
          echo "Whonix version: $v (the current stable release)"
        fi
        if ! [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
          reason="not a version: $v"
          return 1
        fi
        if [ "$(printf '%s\n' "${whonixMinVersion}" "$v" | sort -V | head -n1)" != "${whonixMinVersion}" ]; then
          reason="version $v is older than the minimum ${whonixMinVersion} (downgrade?)"
          return 1
        fi
        archive="Whonix-CLI-$v.Intel_AMD64.qcow2.libvirt.xz"
        # On the new disk: the live system's /tmp is RAM
        work=/mnt/var/tmp/nox-install-whonix
        if [ "$dry_run" = 1 ]; then
          echo "dry-run: $archive (+ .asc, derivative.asc) to $work, signature by $fpr"
          echo "dry-run: tar -xJf $archive (Gateway), qemu-img convert -O raw -S 4k to /mnt$image"
          echo "dry-run: nixos-enter --root /mnt -c '$system/sw/bin/xen-image-setup whonix-gateway'"
        else
          mkdir -p "$work" || { reason="cannot create $work"; return 1; }
          if [ -n "$whonix_from" ]; then
            cp "$whonix_from/$archive" "$whonix_from/$archive.asc" "$whonix_from/derivative.asc" "$work/" \
              || { reason="cannot copy the files from $whonix_from"; return 1; }
          else
            base="https://www.whonix.org/download/libvirt/$v"
            until curl -fSL -C - -o "$work/$archive" "$base/$archive"; do
              yes_no "Download failed. Try again (it continues)?" \
                || { reason="download of $archive failed"; return 1; }
            done
            curl -fsSL -o "$work/$archive.asc" "$base/$archive.asc" \
              || { reason="download of $archive.asc failed"; return 1; }
            curl -fsSL -o "$work/derivative.asc" https://www.whonix.org/keys/derivative.asc \
              || { reason="download of derivative.asc failed"; return 1; }
          fi
          export GNUPGHOME="$work/gnupg"
          rm -rf "$GNUPGHOME" || { reason="cannot clear $GNUPGHOME"; return 1; }
          mkdir -m 700 "$GNUPGHOME" || { reason="cannot create $GNUPGHOME"; return 1; }
          gpg --batch --quiet --import "$work/derivative.asc" \
            || { reason="cannot import derivative.asc"; return 1; }
          if ! gpg --batch --with-colons --fingerprint | grep -q "^fpr:::::::::$fpr:"; then
            reason="derivative.asc does not hold the Whonix key $fpr"
            return 1
          fi
          # Good (GOODSIG: not by an expired or revoked key), by that key
          # (VALIDSIG ends with the primary key's fingerprint), made for this
          # file (notation file@name: Whonix signs the file name too, against
          # an older signed archive under the new name)
          gpg --batch --status-fd 1 --verify "$work/$archive.asc" "$work/$archive" \
            >"$work/verify" 2>/dev/null || true
          if ! grep -aq "^\[GNUPG:\] GOODSIG " "$work/verify" \
            || ! grep -aqE "^\[GNUPG:\] VALIDSIG .* $fpr\$" "$work/verify" \
            || ! grep -aqxF "[GNUPG:] NOTATION_DATA $archive" "$work/verify"; then
            reason="BAD SIGNATURE on $archive"
            return 1
          fi
          echo "Signature good ($fpr)."
          unset GNUPGHOME
          tar -C "$work" -xJf "$work/$archive" --wildcards '*Gateway*' \
            || { reason="cannot unpack $archive"; return 1; }
          mkdir -p "$(dirname "/mnt$image")" || { reason="cannot create the image directory"; return 1; }
          written=1
          qemu-img convert -p -O raw -S 4k "$work"/Whonix-Gateway-*.qcow2 "/mnt$image" \
            || { reason="qemu-img convert failed"; return 1; }
          rm -rf "$work" || { reason="cannot remove $work"; return 1; }
          # The units into the stopped image (debugfs, works offline)
          nixos-enter --root /mnt -c "$system/sw/bin/xen-image-setup whonix-gateway" \
            || { reason="xen-image-setup failed"; return 1; }
          # An image in the home belongs to the user
          case "$image" in
            "/home/$user/"*)
              nixos-enter --root /mnt -c "chown -R $user: /home/$user" \
                || { reason="cannot chown the image"; return 1; }
              ;;
          esac
          echo "Whonix-Gateway image: $image. After the first boot enable Tor in it (README \"Whonix\": DisableNetwork 0)."
        fi
        return 0
      }
      written=0
      if ! whonix_install; then
        unset GNUPGHOME
        if [ "$dry_run" != 1 ]; then
          [ -z "$work" ] || rm -rf "$work"
          # Never leave a half-written or unverified image
          [ "$written" = 0 ] || rm -f "/mnt$image"
        fi
        echo "Whonix-Gateway not installed: $reason." >&2
        echo "The system works without it; set it up by hand later (the Whonix steps of your config's README)." >&2
      fi
    fi

    step "9/9 Password of $user"
    if [ "$dry_run" = 1 ]; then
      echo "dry-run: nixos-enter --root /mnt -c 'passwd $user'"
    else
      until nixos-enter --root /mnt -c "passwd $user"; do :; done
    fi
    rm -rf "$keys"

    echo
    echo "Done: the minimal system is installed. Remove the stick and reboot (reboot);"
    echo "at boot: the LUKS passphrase."
    if [ -n "$builders" ]; then
      echo "After the first login \`nox update\` builds and installs the rest (every VM) on"
      echo "the builder. dom0 trusts the builder already (its keys were made here)."
      if [ "$remote" = local ] && [ "$new_config" = 1 ]; then
        echo "The builder gets the config from the config VM: it starts with nox update."
      elif [ -z "$sign_key" ]; then
        echo "It only builds a HEAD on GitHub that you signed: sign the commit \"$msg\""
        echo "first, from a machine with your signing key (git commit --amend -S, then"
        echo "git push --force-with-lease)."
      fi
    fi
  '';
}
