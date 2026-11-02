{ pkgs, ... }:
let
  # The agent's confirmation (keys are added with `ssh-add -c`): a rofi
  # dialog in the session, prompt from ssh-agent as $1. Allow = exit 0 with
  # no output; Deny, Escape or no answer within 30 s = exit 1 (deny). The
  # agent can't tell who asks: the VMs are the github-agent-from-<vm>@…
  # connections open right now (github-agent-forward.nix), none = dom0 itself
  askpass = pkgs.writeShellScript "github-agent-askpass" ''
    [ "''${SSH_ASKPASS_PROMPT:-}" = confirm ] || exit 1
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
    for s in "$XDG_RUNTIME_DIR"/wayland-*; do
      case "$s" in *.lock) continue ;; esac
      [ -S "$s" ] && export WAYLAND_DISPLAY="''${s##*/}" && break
    done
    vms="$(${pkgs.systemd}/bin/systemctl --user list-units --plain --no-legend --state=active \
      'github-agent-from-*@*.service' |
      ${pkgs.gnused}/bin/sed -n 's/^github-agent-from-\([^@]*\)@.*/\1/p' | ${pkgs.coreutils}/bin/sort -u)"
    case "$(printf '%s' "$vms" | ${pkgs.coreutils}/bin/wc -l)" in
      0) [ -n "$vms" ] && who="<b>$vms</b>" || who="<b>dom0</b>" ;;
      *) who="one of <b>$(printf '%s' "$vms" | ${pkgs.coreutils}/bin/paste -sd, | ${pkgs.gnused}/bin/sed 's/,/, /g')</b>" ;;
    esac
    msg="$who wants to use the GitHub key"$'\n'"$(printf '%s' "$1" | ${pkgs.gnused}/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    answer="$(printf 'Deny\nAllow\n' | ${pkgs.coreutils}/bin/timeout 30 ${pkgs.rofi}/bin/rofi -dmenu \
      -theme /etc/xdg/rofi/config.rasi \
      -theme-str 'mainbox { children: [ "inputbar", "message", "listview" ]; }
        message { padding: 10px 14px; background-color: @main-bg; }
        textbox { horizontal-align: 0; background-color: @main-bg; text-color: @main-fg; }
        listview { lines: 2; }' \
      -i -no-custom -p "github?" -mesg "$msg")" || exit 1
    [ "$answer" = Allow ]
  '';
in
pkgs.writeShellScriptBin "github-agent" ''
  #!/usr/bin/env bash
  set -eu

  KEY_PATH="$HOME/.ssh/id_ed25519"
  AGENT_DIR="$HOME/.ssh/agent"

  usage() {
    echo "Usage: github-agent [-k <private-key-path>] [-d <agent-dir>]" >&2
    echo "Defaults:" >&2
    echo "  key:   $HOME/.ssh/id_ed25519" >&2
    echo "  dir:   $HOME/.ssh/agent" >&2
    exit 1
  }

  while getopts ":k:d:h" opt; do
    case "$opt" in
      k) KEY_PATH="$OPTARG" ;;
      d) AGENT_DIR="$OPTARG" ;;
      h) usage ;;
      :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
      \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ $# -ne 0 ]; then
    usage
  fi

  SOCKET_PATH="$AGENT_DIR/github.sock"
  ENV_PATH="$AGENT_DIR/github-agent.env"

  mkdir -p "$AGENT_DIR"
  chmod 700 "$AGENT_DIR"

  if [ ! -f "$KEY_PATH" ]; then
    echo "GitHub SSH key not found at '$KEY_PATH'." >&2
    exit 1
  fi

  agent_is_reachable() {
    local status=0
    ${pkgs.openssh}/bin/ssh-add -l >/dev/null 2>&1 || status=$?
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  }

  reset_agent_state() {
    if [ -n "''${SSH_AGENT_PID:-}" ] && kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
      SSH_AUTH_SOCK="''${SSH_AUTH_SOCK:-$SOCKET_PATH}" \
        SSH_AGENT_PID="$SSH_AGENT_PID" \
        ${pkgs.openssh}/bin/ssh-agent -k >/dev/null 2>&1 || true
    fi

    rm -f "$SOCKET_PATH" "$ENV_PATH"
    unset SSH_AUTH_SOCK SSH_AGENT_PID
  }

  start_agent() {
    # Askpass for the confirmation (ssh-add -c) without DISPLAY: the oneshot
    # unit starts the agent before niri
    eval "$(SSH_ASKPASS=${askpass} SSH_ASKPASS_REQUIRE=force \
      ${pkgs.openssh}/bin/ssh-agent -a "$SOCKET_PATH" -s)" >/dev/null
    # GITHUB_AGENT_CONFIRM: the agent has the askpass; an older one without
    # it would deny every use of a confirm key, so it is replaced
    printf 'SSH_AUTH_SOCK=%s\nSSH_AGENT_PID=%s\nGITHUB_AGENT_CONFIRM=1\n' "$SSH_AUTH_SOCK" "$SSH_AGENT_PID" > "$ENV_PATH"
    chmod 600 "$ENV_PATH"
  }

  if [ -f "$ENV_PATH" ]; then
    # shellcheck disable=SC1090
    . "$ENV_PATH"
    export SSH_AUTH_SOCK="''${SSH_AUTH_SOCK:-$SOCKET_PATH}"
    export SSH_AGENT_PID="''${SSH_AGENT_PID:-}"
  else
    export SSH_AUTH_SOCK="$SOCKET_PATH"
    export SSH_AGENT_PID=""
  fi

  if [ ! -S "$SOCKET_PATH" ] || [ "''${GITHUB_AGENT_CONFIRM:-}" != 1 ] || [ -z "''${SSH_AGENT_PID:-}" ] || ! kill -0 "$SSH_AGENT_PID" 2>/dev/null || ! agent_is_reachable; then
    reset_agent_state
    start_agent
  fi

  can_prompt_for_passphrase() {
    if [ -t 0 ] || [ -t 1 ]; then
      return 0
    fi

    if [ -n "''${SSH_ASKPASS:-}" ] && { [ -n "''${DISPLAY:-}" ] || [ -n "''${WAYLAND_DISPLAY:-}" ]; }; then
      return 0
    fi

    return 1
  }

  ensure_key_loaded() {
    if ! ${pkgs.openssh}/bin/ssh-add -l >/dev/null 2>&1; then
      if can_prompt_for_passphrase; then
        ${pkgs.openssh}/bin/ssh-add -c "$KEY_PATH"
      else
        echo "Agent is running, but key is locked and no interactive prompt is available. Run 'github-agent' manually once per login to unlock." >&2
      fi
      return
    fi

    if [ ! -f "$KEY_PATH.pub" ]; then
      echo "Warning: '$KEY_PATH.pub' not found; skipping identity content check." >&2
      return
    fi

    if ! ${pkgs.openssh}/bin/ssh-add -L 2>/dev/null | ${pkgs.gnugrep}/bin/grep -F "$(cat "$KEY_PATH.pub")" >/dev/null; then
      if can_prompt_for_passphrase; then
        ${pkgs.openssh}/bin/ssh-add -c "$KEY_PATH"
      else
        echo "Agent is running, but target key is not loaded and no interactive prompt is available. Run 'github-agent' manually once per login to unlock." >&2
      fi
    fi
  }

  ensure_key_loaded

  echo "GitHub agent ready at $SOCKET_PATH"
''
