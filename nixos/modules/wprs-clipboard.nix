# Clipboard isolation for wprs (Qubes model, 2026-10-16): wprsd runs with
# `--selection-sync false` (our fork, modules/wprs-overlay.nix) and offers
# wlr-data-control, so wl-copy/wl-paste reach the guest clipboard without a
# window. `helper`: what dom0's vm-clip (home/vm-management/vm-gui.nix) calls
# in the guest. Used by the NixOS VMs (vms/modules/wprs.nix) and the image
# domains (modules/xen-image-domains.nix)
{ pkgs }:
{
  # Called by dom0's vm-clip over SSH: `get` prints the text clipboard,
  # `set` takes it on stdin. wl-copy keeps serving it, detached from SSH
  helper = pkgs.writeShellScriptBin "vm-clip-helper" ''
    set -eu
    export WAYLAND_DISPLAY=wprs-0
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    case "''${1:-}" in
      get) exec ${pkgs.wl-clipboard}/bin/wl-paste --no-newline --type text ;;
      set)
        # wl-copy keeps serving the selection, so it must outlive the SSH
        # connection: Whonix runs each one as its own unit (sshd-vchan@)
        # and stops it on disconnect, so start it in the user manager. The
        # unit opens and deletes the temp file, then reads from the fd
        tmp="$(mktemp)"
        cat >"$tmp"
        systemd-run --user --quiet --collect --setenv=WAYLAND_DISPLAY=wprs-0 \
          /bin/sh -c 'exec 3<"$0"; rm -f "$0"; exec "$1" --foreground --type text/plain <&3 3<&-' \
          "$tmp" ${pkgs.wl-clipboard}/bin/wl-copy || {
          rm -f "$tmp"
          exit 1
        }
        ;;
      *)
        echo "usage: vm-clip-helper get|set" >&2
        exit 2
        ;;
    esac
  '';
}
