{ config, pkgs, lib, inputs, ... }:

let
  cfg = config.steamVmImage;

  steamImageDrv = inputs.steam-vm.packages.${pkgs.system}.steam-os-qcow2;

  imagesDir = "/var/lib/libvirt/images";
  osTarget = "${imagesDir}/steam-os.qcow2";
  dataTarget = "${imagesDir}/steam-data.qcow2";
in
{
  options.steamVmImage = {
    enable = lib.mkEnableOption "Deploy Steam VM OS qcow2 + create persistent data disk for libvirt";

    dataDiskSize = lib.mkOption {
      type = lib.types.str;
      default = "210G";
      description = "Size for the persistent steam data qcow2 (only used on first creation).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.qemu pkgs.coreutils ];

    systemd.services.deploy-steam-vm-image = {
      description = "Deploy Steam VM qcow2 into /var/lib/libvirt/images";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        set -euo pipefail

        install -d -m 0755 "${imagesDir}"

        # Create persistent data disk once
        if [ ! -e "${dataTarget}" ]; then
          echo "Creating ${dataTarget} (${cfg.dataDiskSize})"
          ${pkgs.qemu}/bin/qemu-img create -f qcow2 "${dataTarget}" "${cfg.dataDiskSize}"
          chmod 0644 "${dataTarget}"
          chown libvirt-qemu:kvm "${dataTarget}" 2>/dev/null || true
        fi

        # Deploy OS image atomically (copy out of nix store)
        tmp="$(mktemp -p "${imagesDir}" .steam-os.qcow2.XXXXXX)"

        # makeDiskImage output name differs; take first *.qcow2
        src="$(${pkgs.coreutils}/bin/ls -1 "${steamImageDrv}"/*.qcow2 | ${pkgs.coreutils}/bin/head -n 1)"
        echo "Copying $src -> ${osTarget}"

        ${pkgs.coreutils}/bin/cp --reflink=auto --sparse=always "$src" "$tmp"
        chmod 0644 "$tmp"
        chown libvirt-qemu:kvm "$tmp" 2>/dev/null || true
        ${pkgs.coreutils}/bin/mv -f "$tmp" "${osTarget}"
      '';
    };

    # triggert deploy automatisch bei jedem nixos-rebuild switch
    system.activationScripts.deploySteamVmImage = lib.stringAfter [ "users" ] ''
      ${pkgs.systemd}/bin/systemctl start deploy-steam-vm-image.service || true
    '';
  };
}
