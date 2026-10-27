# nox printers: find the IPP printers in the local network. sys-net names
# its networks (rpc `lan`), sys-print scans them on TCP 631 and asks each
# hit for name and model (rpc `printers`, vms/sys-print). In a terminal: a
# list; `--menu` (menu entry "Drucker suchen"): rofi, the chosen printer's
# address goes into vm-clip's store (paste with Mod+Alt+V into a VM, e.g.
# for `vm-print <ip> <file>`) and into dom0's clipboard. Starts sys-print
# when it isn't running (polkit asks); it keeps running for printing.
{
  lib,
  pkgs,
  vmRegistry,
  ...
}:
let
  noxPrinters = pkgs.writeShellScriptBin "nox-printers" ''
    set -euo pipefail
    menu=0
    case "''${1:-}" in
      "") ;;
      --menu) menu=1 ;;
      *)
        echo "usage: nox printers [--menu]" >&2
        exit 2
        ;;
    esac
    notify() {
      ${pkgs.libnotify}/bin/notify-send -a nox-printers "Drucker" "$1" || true
    }
    fail() {
      [ "$menu" = 0 ] || notify "$1"
      echo "nox printers: $1" >&2
      exit 1
    }

    if ! systemctl is-active --quiet microvm@sys-print.service; then
      [ "$menu" = 0 ] || notify "sys-print startet …"
      echo "starting sys-print …" >&2
      systemctl start microvm@sys-print.service || fail "sys-print startet nicht"
    fi
    # Its relay connects after the boot
    for _ in $(seq 120); do
      [ "$(timeout 5 nox-rpc --dom0 ping sys-print 2>/dev/null)" = ok ] && break
      sleep 1
    done

    nets="$(timeout 20 nox-rpc --dom0 lan sys-net)" || fail "sys-net nennt kein Netz"
    [ -n "$nets" ] || fail "sys-net hat kein lokales Netz (kein WLAN/LAN?)"
    [ "$menu" = 0 ] || notify "Suche in $(tr '\n' ' ' <<<"$nets")…"
    echo "scanning $(tr '\n' ' ' <<<"$nets")…" >&2
    answer="$(timeout 120 nox-rpc --dom0 printers sys-print <<<"$nets")" || fail "Suche in sys-print fehlgeschlagen"
    [[ "$answer" == ok* ]] || fail "sys-print: $answer"
    rows="$(tail -n +2 <<<"$answer")"
    [ -n "$rows" ] || fail "Kein Drucker gefunden (TCP 631) in $(tr '\n' ' ' <<<"$nets")"

    if [ "$menu" = 0 ]; then
      ${pkgs.util-linux}/bin/column -t -s $'\t' -N ADDRESS,NAME,MODEL <<<"$rows"
      exit 0
    fi
    pick="$(${pkgs.gawk}/bin/awk -F '\t' '{ print $2 " – " $3 " – " $1 }' <<<"$rows" |
      rofi -dmenu -i -no-custom -p "Drucker" -theme /etc/xdg/rofi/config.rasi)" || exit 0
    ip="''${pick##* – }"
    # vm-clip's store (vm-gui.nix): Mod+Alt+V pastes it into the focused VM
    store="''${XDG_RUNTIME_DIR:?}/vm-clip"
    (umask 077 && mkdir -p "$store" && printf '%s' "$ip" >"$store/data" && echo dom0 >"$store/source")
    printf '%s' "$ip" | ${pkgs.wl-clipboard}/bin/wl-copy --type text/plain
    notify "$ip kopiert, einfügen mit Mod+Alt+V (VM) oder Strg+V (dom0)"
  '';
in
lib.mkIf (vmRegistry.byName ? sys-print) {
  environment.systemPackages = [ noxPrinters ];
  nox.desktopEntries.nox-printers = {
    name = "Drucker suchen";
    genericName = "Netzwerkdrucker und ihre IP";
    exec = "nox-printers --menu";
    icon = "printer";
    categories = [ "Settings" ];
    terminal = false;
    type = "Application";
  };
}
