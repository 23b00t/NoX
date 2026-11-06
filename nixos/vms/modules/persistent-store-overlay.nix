{
  config,
  lib,
  pkgs,
  vmRegistry,
  ...
}:

let
  cfg = config.services.persistentStoreOverlay;

  nix = config.nix.package;

  vmName = lib.removeSuffix "-vm" (config.networking.hostName or "");
  currentVm = vmRegistry.byName.${vmName} or { };
  # GC thresholds in MB: registry `store.minFree`/`store.maxFree`, else 15/30 %
  # of the overlay (builder: GC at 85 GB used, back down to 70 GB)
  minFree = if cfg.minFree != null then cfg.minFree else cfg.overlaySize * 15 / 100;
  maxFree = if cfg.maxFree != null then cfg.maxFree else cfg.overlaySize * 30 / 100;

  # Dumps the DB entries of all valid paths in the writable overlay. Not only
  # the closure of GC roots: paths of an aborted build are unrooted, would
  # turn invalid after a reboot and get downloaded/built again although their
  # files stay in the overlay.
  nixDumpOverlayDb = pkgs.writeShellScript "nix-db-dump.sh" ''
    set +e
    PATH=${
      lib.makeBinPath [
        nix
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gnused
      ]
    }
    # Runs at shutdown, when nix-daemon may already be gone: use the DB directly
    export NIX_REMOTE=local

    db="/persist/overlay.db"
    tmp_paths="$(mktemp)"
    tmp_invalid="$(mktemp)"
    tmp_db="$(mktemp -p /persist)"
    trap 'rm -f "$tmp_paths" "$tmp_invalid" "$tmp_db"' EXIT

    # `nix build` out-links register their GC roots in the volatile /nix/var:
    # remember them (name, target), nix-db-restore recreates them
    find /nix/var/nix/gcroots/auto -mindepth 1 -maxdepth 1 -type l -printf '%f\t%l\n' \
      > /persist/auto-roots 2>/dev/null

    # Store paths in the upper dir (whiteouts are character devices; skip
    # .links and anything that is no store path name; lock files are not
    # valid and drop out below)
    find /nix/.rw-store/store -mindepth 1 -maxdepth 1 ! -type c -printf '%f\n' \
      | grep -E '^[0-9a-z]{32}-' \
      | sed 's|^|/nix/store/|' > "$tmp_paths"

    xargs -r nix-store --check-validity --print-invalid < "$tmp_paths" > "$tmp_invalid"
    grep -vxFf "$tmp_invalid" "$tmp_paths" | xargs -r nix-store --dump-db > "$tmp_db"

    # Only replace the old dump with a complete new one
    if [ -s "$tmp_db" ]; then
      mv "$tmp_db" "$db"
    fi
  '';

  nixLoadOverlayDb = pkgs.writeShellScript "nix-db-restore.sh" ''
    set +e
    # --load-db is refused through nix-daemon: use the DB directly
    export NIX_REMOTE=local

    # The own closure, from the image: microvm.nix loads it through the merged
    # store at boot, but closure-info is no valid path, a GC deletes it there
    # and the whiteout makes that load fail. Then the whole system counts as
    # dead and the next GC deletes it (vanilla, 2026-10-31)
    if [[ "$(${pkgs.coreutils}/bin/cat /proc/cmdline)" =~ regInfo=/nix/store/([^\ /]+)/registration ]]; then
      reg="/nix/.ro-store/''${BASH_REMATCH[1]}/registration"
      [ -r "$reg" ] && ${nix}/bin/nix-store --load-db < "$reg"
    fi

    # In a store group: the whole image's registration and GC roots on all
    # its members' toplevels (vms/store-groups.nix groupInfos), so the GC
    # never deletes another member's paths from the image and an imperative
    # install reuses them. Roots in /nix/var, recreated on every boot
    if [[ "$(${pkgs.coreutils}/bin/cat /proc/cmdline)" =~ noxStoreGroup=/nix/store/([^\ /]+) ]]; then
      group="/nix/.ro-store/''${BASH_REMATCH[1]}"
      if [ -r "$group/registration" ]; then
        ${nix}/bin/nix-store --load-db < "$group/registration"
        mkdir -p /nix/var/nix/gcroots/nox-image
        while read -r p; do
          [[ "$p" =~ ^/nix/store/[0-9a-z]{32}-[^/]+$ ]] || continue
          ln -sfn "$p" "/nix/var/nix/gcroots/nox-image/''${p#/nix/store/}"
        done < "$group/roots"
      fi
    fi

    if [ -f /persist/overlay.db ] && [ -s /persist/overlay.db ]; then
      # --load-db is all or nothing: drop entries whose files or references
      # are gone (e.g. paths of an older store image), repeated until stable.
      # A reference that is no entry of the dump must already be valid.
      ${pkgs.gawk}/bin/awk '
        FILENAME == ARGV[1] { valid[$0] = 1; next }
        FILENAME == ARGV[2] { onDisk["/nix/store/" $0] = 1; next }
        { line[++nl] = $0 }
        END {
          i = 1
          while (i <= nl) {
            n++; start[n] = i; rec[line[i]] = n
            nrefs[n] = line[i + 4]
            for (j = 1; j <= nrefs[n]; j++) ref[n, j] = line[i + 4 + j]
            i += 5 + nrefs[n]
          }
          for (k = 1; k <= n; k++) keep[k] = (line[start[k]] in onDisk)
          do {
            changed = 0
            for (k = 1; k <= n; k++) {
              if (!keep[k]) continue
              for (j = 1; j <= nrefs[k]; j++) {
                r = ref[k, j]
                if ((r in rec) ? !keep[rec[r]] : !(r in valid)) {
                  keep[k] = 0; changed = 1; break
                }
              }
            }
          } while (changed)
          for (k = 1; k <= n; k++)
            if (keep[k])
              for (i = start[k]; i < start[k] + 5 + nrefs[k]; i++) print line[i]
        }' <(${nix}/bin/nix --extra-experimental-features nix-command path-info --all) \
        <(${pkgs.coreutils}/bin/ls /nix/store) /persist/overlay.db \
        | ${nix}/bin/nix-store --load-db
    fi

    mkdir -p /nix/var/nix/gcroots/auto
    if [ -f /persist/auto-roots ]; then
      while IFS=$'\t' read -r name target; do
        # Root names are store-path hashes
        [[ "$name" =~ ^[0-9a-z]+$ ]] || continue
        ln -sfn "$target" "/nix/var/nix/gcroots/auto/$name"
      done < /persist/auto-roots
    fi
  '';
in
{
  options.services.persistentStoreOverlay = {
    enable = lib.mkEnableOption "Enable persistent store overlay for microvms";

    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "VM user";
    };

    overlaySize = lib.mkOption {
      type = lib.types.int;
      default = 23000;
      description = "Size of the writable store overlay in MB.";
    };

    minFree = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = currentVm.storeMinFree or null;
      defaultText = lib.literalExpression "registry `store.minFree`";
      description = "Free space in the overlay in MB below which Nix collects garbage during a build or download. null: 15 % of `overlaySize`.";
    };

    maxFree = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = currentVm.storeMaxFree or null;
      defaultText = lib.literalExpression "registry `store.maxFree`";
      description = "Free space in the overlay in MB up to which such a collection deletes dead paths. null: 30 % of `overlaySize`.";
    };

    gcTimer = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Collect all dead paths 3 min after each boot and then daily, and trim afterwards. Without it only `minFree` triggers a GC, so dead paths stay until the overlay is nearly full.";
    };

    dbDirSize = lib.mkOption {
      type = lib.types.int;
      default = 512;
      description = "Size of the Nix DB overlay in MB.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = maxFree > minFree;
        message = "${vmName}: store.maxFree (${toString maxFree} MB) must be greater than store.minFree (${toString minFree} MB)";
      }
    ];

    microvm = {
      writableStoreOverlay = "/nix/.rw-store";
      volumes = [
        {
          image = "nix-store-overlay.img";
          mountPoint = "/nix/.rw-store";
          size = cfg.overlaySize;
        }
        {
          image = "nix-db.img";
          mountPoint = "/persist";
          size = cfg.dbDirSize;
        }
      ];
      shares = [
        {
          proto = "virtiofs";
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
        }
      ];
    };

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      substituters = [
        "https://cache.nixos.org"
        "https://microvm.cachix.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
      trusted-users = [
        cfg.user
      ];
      # GC only when space runs low; the store keeps old paths for fast rebuilds
      min-free = minFree * 1024 * 1024;
      max-free = maxFree * 1024 * 1024;
    };

    # min-free alone keeps dead paths until the overlay is nearly full (nox:
    # 81 % dead, 2026-10-31). The 03:15 calendar timer with Persistent= would
    # keep its stamp on the tmpfs root (same trap as fstrim, registry
    # definitions.nix): run after each boot and daily instead
    nix.gc = lib.mkIf cfg.gcTimer {
      automatic = true;
      persistent = false;
    };
    systemd = {
      timers.nix-gc.timerConfig = lib.mkIf cfg.gcTimer {
        OnCalendar = lib.mkForce [ ];
        OnBootSec = "3min";
        OnUnitActiveSec = "1d";
      };
      services = {
        nix-gc = lib.mkIf cfg.gcTimer {
          # root uses the local store directly, not the daemon that waits for it
          after = [ "nix-db-restore.service" ];
          # give the freed blocks back to dom0 right away
          onSuccess = [ "fstrim.service" ];
        };

        nix-db-backup = {
          description = "Backup overlay-related Nix DB entries on shutdown";
          wantedBy = [ "multi-user.target" ];
          before = [ "shutdown.target" ];
          after = [ "local-fs.target" ];

          unitConfig.RequiresMountsFor = [
            "/nix"
            "/persist"
          ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
            ExecStop = "${nixDumpOverlayDb}";
            User = "root";
            TimeoutStopSec = "5min";
          };
        };

        nix-db-restore = {
          description = "Restore overlay-related Nix DB entries at boot";
          # nix-daemon waits for it: until then the overlay's paths count as
          # invalid, Nix fetches or builds them again and a GC deletes them. The
          # socket queues connections meanwhile (builder-build came in 3 s into
          # the 17 s restore, 2026-11-02)
          wantedBy = [
            "multi-user.target"
            "nix-daemon.service"
          ];
          before = [
            "multi-user.target"
            "nix-daemon.service"
          ];
          after = [ "local-fs.target" ];

          unitConfig.RequiresMountsFor = [
            "/nix"
            "/persist"
          ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${nixLoadOverlayDb}";
            User = "root";
            TimeoutSec = "5min";
          };
        };
      };
    };
  };
}
