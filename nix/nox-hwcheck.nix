# nox-hwcheck: can this machine run NoX, and what goes where? A report with
# traffic lights (virtualisation, firmware, RAM, disk, IOMMU groups, GPUs,
# network and USB for the driver domains, CPU) and, with --nix, a block for
# the config's machines/hardware.nix (format of template/machines). Runs on a
# live system and in a running dom0; under Xen it reads Xen's view (`xl
# info`, `xl dmesg`), since dom0 sees neither VT-x nor the IOMMU groups.
# Changes nothing. Some values need root.
{
  writeShellApplication,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  pciutils,
  usbutils,
  util-linux,
}:
writeShellApplication {
  name = "nox-hwcheck";
  runtimeInputs = [
    coreutils
    gawk
    gnugrep
    gnused
    pciutils
    usbutils
    util-linux
  ];
  text = ''
    mode=report
    case "''${1:-}" in
      "") ;;
      --nix) mode=nix ;;
      -h | --help)
        echo "usage: nox-hwcheck [--nix]   (report; --nix: block for machines/hardware.nix)"
        exit 0
        ;;
      *)
        echo "usage: nox-hwcheck [--nix]" >&2
        exit 2
        ;;
    esac

    if [ -t 1 ]; then
      G=$'\e[32m' O=$'\e[33m' R=$'\e[31m' B=$'\e[1m' N=$'\e[0m'
    else
      G="" O="" R="" B="" N=""
    fi
    ok() { echo "  ''${G}✔''${N} $*"; }
    warn() { echo "  ''${O}▲''${N} $*"; }
    bad() { echo "  ''${R}✘''${N} $*"; }
    info() { echo "    $*"; }
    head1() { echo; echo "''${B}$*''${N}"; }

    root=0
    [ "$(id -u)" = 0 ] && root=1
    xen=0
    grep -qs control_d /proc/xen/capabilities && xen=1
    # Under Xen the machine's RAM, CPUs and virtualisation come from xl (as
    # root, or through sudo without a password where that is allowed)
    have_xl=0
    xl=(xl)
    if [ "$xen" = 1 ] && command -v xl >/dev/null; then
      if [ "$root" = 1 ]; then
        have_xl=1
      elif sudo -n xl info >/dev/null 2>&1; then
        have_xl=1
        xl=(sudo -n xl)
      fi
    fi
    xlinfo=""
    xldmesg=""
    if [ "$have_xl" = 1 ]; then
      xlinfo="$("''${xl[@]}" info 2>/dev/null || true)"
      xldmesg="$("''${xl[@]}" dmesg 2>/dev/null || true)"
    fi
    kmsg="$(dmesg 2>/dev/null || true)"

    # PCI: "slot class vendor:device" per line; names and drivers on demand
    pcilist="$(lspci -Dn | awk '{ sub(":$", "", $2); print $1, $2, $3 }')"
    pciname() { lspci -s "$1" -mm | awk -F'"' '{ print $4 " " $6 }'; }
    pcidriver() { lspci -ks "$1" | awk -F': ' '/Kernel driver in use/ { print $2 }'; }
    pcimodule() { lspci -ks "$1" | awk -F': ' '/Kernel modules/ { print $2 }' | awk -F', ' '{ print $1 }'; }
    byclass() { awk -v re="$1" '$2 ~ re { print $1 }' <<<"$pcilist"; }

    gpus="$(byclass '^03')"
    nics="$(byclass '^02')"
    usbs="$(byclass '^0c03')"
    bootvga() { [ "$(cat "/sys/bus/pci/devices/$1/boot_vga" 2>/dev/null)" = 1 ]; }
    dgpus=""
    for g in $gpus; do bootvga "$g" || dgpus="$dgpus $g"; done
    # The dGPU's other functions (HDMI audio): same slot, other function
    gpufuncs() { local s="''${1%.*}"; awk -v s="$s" 'index($1, s ".") == 1 { print $1 }' <<<"$pcilist"; }

    cpuvendor=intel
    grep -q AuthenticAMD /proc/cpuinfo && cpuvendor=amd

    # USB inventory: "vendor:product class name" (class: input, bluetooth,
    # video, other). Live system: lsusb with the interface classes; dom0
    # under Xen: the controllers are in sys-usb, vm-usb lists what it sees
    usbinv() {
      local d id cls name ifs
      if [ -n "$(ls /sys/bus/usb/devices 2>/dev/null)" ]; then
        for d in /sys/bus/usb/devices/*; do
          [ -f "$d/idVendor" ] || continue
          [ "$(cat "$d/bDeviceClass")" = 09 ] && continue # hubs
          id="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
          ifs="$(cat "$d"/*:*/bInterfaceClass 2>/dev/null | sort -u | tr '\n' ' ')"
          cls=other
          case " $ifs " in
            *" 03 "*) cls=input ;;
            *" e0 "*) cls=bluetooth ;;
            *" 0e "*) cls=video ;;
          esac
          [ "$(cat "$d/bDeviceClass")" = e0 ] && cls=bluetooth
          name="$(cat "$d/product" 2>/dev/null || echo "$id")"
          echo "$id $cls $name"
        done
      elif command -v vm-usb >/dev/null; then
        vm-usb list 2>/dev/null | awk 'NR > 1 && $4 != "" { print $2, "unknown", $3 }'
      fi
    }

    if [ "$mode" = nix ]; then
      slug() { tr '[:upper:]' '[:lower:]' <<<"$*" | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' | cut -c1-28; }
      nicmods="" wifimods=""
      for n in $nics; do
        m="$(pcimodule "$n")"
        [ -n "$m" ] || m="$(pcidriver "$n")"
        case "$(awk -v s="$n" '$1 == s { print $2 }' <<<"$pcilist")" in
          0280) wifimods="$wifimods \"$m\"" ;;
          *) nicmods="$nicmods \"$m\"" ;;
        esac
      done
      dvendor=""
      for g in $dgpus; do
        case "$(awk -v s="$g" '$1 == s { print $3 }' <<<"$pcilist")" in
          10de:*) dvendor=nvidia ;;
          1002:*) dvendor=amd ;;
        esac
      done
      echo "# nox-hwcheck --nix on $(cat /proc/sys/kernel/hostname), $(date +%F); review before use"
      echo "{"
      echo "  profile = {"
      echo "    cpuVendor = \"$cpuvendor\";"
      echo "    # PV dom0 (true) or PVH (false); see the report for the reasons"
      echo "    dom0Pv = false;"
      if [ -n "$dvendor" ]; then
        echo "    dGpuVendor = \"$dvendor\";"
      fi
      echo "    blockedHostDrivers = {"
      echo "      nic = [$nicmods ];"
      echo "      wifi = [$wifimods ];"
      echo "    };"
      echo "  };"
      echo "  pciDevicePaths = {"
      echo "    nic = ["
      for n in $nics; do echo "      \"$n\" # $(pciname "$n")"; done
      echo "    ];"
      echo "    usb = ["
      for u in $usbs; do echo "      \"$u\" # $(pciname "$u")"; done
      echo "    ];"
      if [ -n "$dgpus" ]; then
        echo "    gpu = ["
        for g in $dgpus; do
          for f in $(gpufuncs "$g"); do echo "      \"$f\" # $(pciname "$f")"; done
        done
        echo "    ];"
      fi
      echo "  };"
      echo "  pciDeviceIds.nic = [ ];"
      echo "  usbDevices = ["
      usbinv | while read -r id cls name; do
        v="''${id%%:*}" p="''${id##*:}"
        case "$cls" in
          input) pol=host-allow own=host allowed='"host"' bt="" ;;
          bluetooth) pol=vm-reserved own=sys-usb allowed='"sys-usb"' bt="      bluetooth = true;" ;;
          unknown) pol=vm-reserved own=sys-usb allowed='"sys-usb"' bt="      # class unknown (dom0 under Xen): input devices are host-allow" ;;
          *) pol=vm-reserved own=sys-usb allowed='"sys-usb"' bt="" ;;
        esac
        echo "    {"
        echo "      name = \"$(slug "$name")\";"
        echo "      vendorId = \"$v\";"
        echo "      productId = \"$p\";"
        echo "      policy = \"$pol\";"
        echo "      defaultOwner = \"$own\";"
        echo "      allowedOwners = [ $allowed ];"
        [ -z "$bt" ] || echo "$bt"
        echo "      microvmUsbPath = \"vendorid=0x$v,productid=0x$p\";"
        echo "    }"
      done
      echo "  ];"
      echo "}"
      exit 0
    fi

    echo "''${B}nox-hwcheck''${N} on $(cat /proc/sys/kernel/hostname)$([ "$xen" = 1 ] && echo " (dom0 under Xen)")"
    [ "$root" = 1 ] || warn "not root: some values missing (run with sudo)"

    head1 "Virtualisation"
    if [ "$xen" = 1 ]; then
      if [ "$have_xl" = 1 ]; then
        caps="$(awk -F': ' '/^virt_caps/ { print $2 }' <<<"$xlinfo")"
        if grep -qw hvm <<<"$caps"; then ok "VT-x/AMD-V (Xen: hvm)"; else bad "no VT-x/AMD-V (Xen sees no hvm): enable it in the firmware setup"; fi
        if grep -qw hvm_directio <<<"$caps"; then ok "VT-d/AMD-Vi (Xen: hvm_directio)"; else bad "no VT-d/AMD-Vi: enable it in the firmware setup (passthrough needs it)"; fi
      else
        warn "under Xen without xl as root: run with sudo"
      fi
    else
      vmx=0 iommu=0
      grep -Eqw 'vmx|svm' /proc/cpuinfo && vmx=1
      [ -n "$(ls /sys/class/iommu 2>/dev/null)" ] && iommu=1
      if [ "$vmx" = 1 ]; then ok "VT-x/AMD-V"; else bad "no VT-x/AMD-V: enable it in the firmware setup"; fi
      if [ "$iommu" = 1 ]; then
        ok "VT-d/AMD-Vi (IOMMU active)"
      else
        bad "no IOMMU: enable VT-d/AMD-Vi in the firmware setup (and intel_iommu=on / amd_iommu=on)"
      fi
      if [ "$vmx" != "$iommu" ]; then
        info "only one of the two: in theory NoX could run its VMs paravirtualised (PV), but"
        info "that is not documented and costs performance and security"
      fi
    fi

    head1 "Firmware"
    if [ -d /sys/firmware/efi ]; then ok "UEFI"; else bad "legacy BIOS boot: NoX installs for UEFI"; fi
    sb="$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')"
    case "$sb" in
      1) warn "Secure Boot on: Xen and the unsigned kernels don't boot with it; switch it off" ;;
      0) ok "Secure Boot off" ;;
      *) info "Secure Boot: unknown" ;;
    esac
    if grep -qi 'Interrupt remapping enabled' <<<"$xldmesg$kmsg" || grep -qiE 'DMAR-IR: Enabled|AMD-Vi: Interrupt remapping enabled' <<<"$kmsg"; then
      ok "interrupt remapping"
    elif [ "$root" = 1 ]; then
      warn "interrupt remapping not seen: passthrough is less isolated (check the firmware's IOMMU options)"
    fi

    head1 "Memory and disk"
    mem=""
    if [ -n "$xlinfo" ]; then
      mem="$(awk -F': ' '/^total_memory/ { print $2 }' <<<"$xlinfo")"
    elif [ "$xen" = 0 ]; then
      mem="$(awk '/^MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo)"
    fi
    if [ -z "$mem" ]; then
      info "RAM: dom0 sees only its own share, run with sudo"
    else
      memgb=$(((mem + 512) / 1024))
      if [ "$mem" -ge 30000 ]; then ok "RAM ''${memgb} GB"; elif [ "$mem" -ge 15000 ]; then warn "RAM ''${memgb} GB: enough for a few VMs (32 GB recommended)"; else bad "RAM ''${memgb} GB: too little for NoX (16 GB minimum, 32 recommended)"; fi
    fi
    disk="$(lsblk -dbn -o SIZE,TYPE,NAME | awk '$2 == "disk" && $3 !~ /^(zram|loop)/ && $1 > max { max = $1; n = $3 } END { if (n) printf "%d %s", max / 1e9, n }')"
    dsize="''${disk%% *}"
    if [ -z "$disk" ]; then warn "no disk found"
    elif [ "$dsize" -ge 500 ]; then ok "disk ''${disk#* } ''${dsize} GB"
    elif [ "$dsize" -ge 250 ]; then warn "disk ''${disk#* } ''${dsize} GB: fine for a lean fleet (500 GB recommended)"
    else bad "disk ''${disk#* } ''${dsize} GB: too small (250 GB minimum)"; fi

    head1 "IOMMU groups"
    if [ -n "$(ls /sys/kernel/iommu_groups 2>/dev/null)" ]; then
      for g in /sys/kernel/iommu_groups/*; do
        devs="$(ls "$g/devices")"
        # Clean: one slot (its functions) plus bridges
        slots="$(for d in $devs; do
          c="$(awk -v s="$d" '$1 == s { print $2 }' <<<"$pcilist")"
          case "$c" in 06*) ;; *) echo "''${d%.*}" ;; esac
        done | sort -u | wc -l)"
        line="group ''${g##*/}: $(for d in $devs; do printf '%s ' "$d"; done)"
        if [ "$slots" -le 1 ]; then info "$line"; else warn "$line(several devices: only together to one VM)"; fi
      done
    else
      info "not visible here (under Xen the IOMMU belongs to Xen): run nox-hwcheck from the"
      info "live system for the groups; Xen assigns all functions of a device together"
    fi

    head1 "Graphics"
    for g in $gpus; do
      if bootvga "$g"; then info "$g $(pciname "$g") (drives the boot screen: dom0's desktop)"
      else ok "$g $(pciname "$g"): free for passthrough (gpu = true), functions: $(gpufuncs "$g" | tr '\n' ' ')"; fi
    done
    [ -n "$dgpus" ] || warn "one GPU only: dom0 needs it, no GPU passthrough (VMs draw in software over wprs)"

    head1 "Network (sys-net) and USB (sys-usb)"
    for n in $nics; do
      ok "$n $(pciname "$n") [driver: $(pcidriver "$n")$( [ -n "$(pcimodule "$n")" ] && echo ", module $(pcimodule "$n")")] -> sys-net"
    done
    [ -n "$nics" ] || bad "no network card: sys-net has nothing to drive"
    for u in $usbs; do
      ok "$u $(pciname "$u") -> sys-usb"
      for n in $nics; do
        [ "''${n%.*}" = "''${u%.*}" ] && warn "  shares its slot with the network card $n (both functions of one device; check that each has its own reset)"
      done
    done
    [ -n "$usbs" ] || warn "no USB controller found"
    if grep -qE 'Phys=(isa0060|i2c|.*i2c)' /proc/bus/input/devices 2>/dev/null; then
      ok "internal keyboard/touchpad (i8042/I2C): stays in dom0"
    else
      warn "keyboard/mouse only over USB: input reaches dom0 through sys-usb's input proxy (no keyboard if sys-usb fails; sys-usb-rescue)"
    fi
    inv="$(usbinv)"
    if [ -n "$inv" ]; then
      info "USB devices (nox-hwcheck --nix writes them as usbDevices):"
      while read -r id cls name; do info "  $id $cls $name"; done <<<"$inv"
    fi

    head1 "CPU"
    if [ -n "$xlinfo" ]; then
      ok "$(awk -F': ' '/^nr_cpus/ { print $2 }' <<<"$xlinfo") threads (Xen), $(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
      info "P/E cores: not visible from dom0, run from the live system"
    elif [ "$xen" = 1 ]; then
      info "CPU: dom0 sees only its own vCPUs, run with sudo"
    else
      ok "$(nproc --all) threads, $(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
      if [ -d /sys/devices/cpu_core ] && [ -d /sys/devices/cpu_atom ]; then
        info "hybrid: P-cores $(cat /sys/devices/cpu_core/cpus), E-cores $(cat /sys/devices/cpu_atom/cpus)"
        info "suggestion: give a gaming VM the P-cores in its own cpupool (like the xmg's steam)"
      fi
    fi
    shared="$(awk 'NR > 1 && $NF ~ /,/ { print }' /proc/interrupts | sed 's/  */ /g')"
    if [ -n "$shared" ]; then
      warn "shared interrupt lines (a passed-through device sharing one with dom0 can stall; xmg: GSI 18)"
      while read -r l; do info "  $l"; done <<<"$shared"
    fi
    fw="$(grep -ciE 'firmware bug|bios bug|ACPI BIOS (Warning|Error)' <<<"$kmsg" || true)"
    [ "$fw" -gt 0 ] && info "$fw firmware warnings in the kernel log (dmesg | grep -iE 'firmware bug|bios')"
    exit 0
  '';
}
