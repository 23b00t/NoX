# Builder VM (v2.4): evaluates and builds the host systems (incl. all MicroVMs
# and store group images) from the GitHub repo and signs the closures with its
# own key. dom0 pulls the result with `dom0-update` (modules/dom0-update.nix);
# the builder never pushes into dom0.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  stateDir = "/var/lib/builder";
  inherit (config.nox.builder) repoUrl;
  # The builder's registry entry (memory, memoryMax) as this machine sees it
  # (byName is the machine-independent view)
  reg = lib.findFirst (vm: vm.name == "builder") vmRegistry.byName.builder vmRegistry.vms;

  # The builders' keys for flake.lock bumps (builder-build --bump), one line
  # per machine; without the file no bump commit is built
  bumpSigners = vmRegistry.builderKeys + "/bump-signers";
  hasBumpSigners = builtins.pathExists bumpSigners;

  # builder-build [--bump] <machine> [branch]: fetch, build, sign; prints the
  # toplevel. --bump first updates the flake inputs and pushes flake.lock as
  # a signed commit "update" of its own (nox update).
  # builder-build --iso <branch>: builds the config's installer-iso and
  # prints its store path, without GC root or signature: dom0-update
  # --iso <vm> streams it from here to the VM and then deletes it
  builderBuild = pkgs.writeShellScriptBin "builder-build" ''
    set -euo pipefail
    # Hand the blocks of the build directories and collected paths back to
    # dom0 (the boot's timer runs before the build). In the background, the
    # build's result doesn't wait for it; the store's content stays
    trap '/run/wrappers/bin/sudo -n ${config.systemd.package}/bin/systemctl start --no-block fstrim.service >/dev/null 2>&1 || true' EXIT
    bump=0
    if [ "''${1:-}" = --bump ]; then
      bump=1
      shift
    fi
    machine="''${1:?usage: builder-build [--bump] <machine> [branch] | --iso <branch>}"
    branch="''${2:-$machine}"
    attr="nixosConfigurations.$machine.config.system.build.toplevel"
    # The out-link is the GC root of the last build per machine
    link=(--out-link "${stateDir}/systems/$machine")
    if [ "$machine" = --iso ]; then
      branch="''${2:?usage: builder-build --iso <branch>}"
      machine=installer-iso
      attr=installer-iso
      link=(--no-link)
      bump=0
    fi
    repo="${stateDir}/repo"
    key="${stateDir}/signing-key"
    bumpkey="${stateDir}/bump-key"

    [ -r "$key" ] || { echo "builder-build: signing key $key missing" >&2; exit 1; }
    if [ "$bump" = 1 ]; then
      [ -r "$bumpkey" ] || { echo "builder-build: bump key $bumpkey missing" >&2; exit 1; }
      ${lib.optionalString (!hasBumpSigners) ''
        echo "builder-build: vms/builder/bump-signers is missing, a bump commit would not be built (README \"Builder\")" >&2
        exit 1
      ''}
    fi

    # SSH URLs (a private config): the builder's own read-only deploy key
    # and GitHub's pinned host key (programs.ssh.knownHosts below), no agent.
    # The push of a bump goes with the bump key (write access)
    git_ssh() {
      echo "${pkgs.openssh}/bin/ssh -i $1 -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null"
    }
    GIT_SSH_COMMAND="$(git_ssh ${stateDir}/deploy-key)"
    export GIT_SSH_COMMAND

    if [ ! -d "$repo/.git" ]; then
      ${pkgs.git}/bin/git clone --quiet ${lib.escapeShellArg repoUrl} "$repo" >&2
    fi
    # A changed repoUrl (e.g. https -> ssh when the config went private)
    # applies to the existing checkout too
    ${pkgs.git}/bin/git -C "$repo" remote set-url origin ${lib.escapeShellArg repoUrl}
    ${pkgs.git}/bin/git -C "$repo" fetch --quiet origin "$branch" >&2
    ${pkgs.git}/bin/git -C "$repo" checkout --quiet --detach FETCH_HEAD >&2
    echo "builder-build: $machine from $branch @ $(${pkgs.git}/bin/git -C "$repo" rev-parse --short HEAD)" >&2

    # Only commits signed by an allowed key get built: a compromised GitHub
    # account or repo alone cannot push a system into dom0. Either signed by
    # the user (allowed-signers), or a builder's flake.lock bump
    # (bump-signers): one parent, nothing but flake.lock changed, on top of
    # a commit trusted the same way (bumps in a row end at a user's commit).
    # The builder is fully trusted anyway (it signs the closure), and the
    # inputs it locks come from the user's flake.nix
    signed_by() {
      ${pkgs.git}/bin/git -C "$repo" \
        -c gpg.ssh.program=${pkgs.openssh}/bin/ssh-keygen \
        -c gpg.ssh.allowedSignersFile="$2" \
        verify-commit "$1" 2>/dev/null
    }
    trusted() {
      local c=$1 _
      for _ in $(seq 50); do
        signed_by "$c" ${vmRegistry.builderKeys + "/allowed-signers"} && return 0
        ${
          if hasBumpSigners then
            ''
              signed_by "$c" ${bumpSigners} || return 1
              [ "$(${pkgs.git}/bin/git -C "$repo" rev-list --no-walk --parents "$c" | wc -w)" = 2 ] || return 1
              [ "$(${pkgs.git}/bin/git -C "$repo" diff --name-only "$c^" "$c")" = flake.lock ] || return 1
              echo "builder-build: $(${pkgs.git}/bin/git -C "$repo" rev-parse --short "$c") is a builder's flake.lock bump" >&2
              c="$c^"
            ''
          else
            "return 1"
        }
      done
      return 1
    }
    if ! trusted HEAD; then
      echo "builder-build: HEAD of $branch is not signed by a key in vms/builder/allowed-signers (nor a builder's flake.lock bump, bump-signers), not building" >&2
      exit 1
    fi

    # nox update: new inputs as a commit of their own, pushed before the
    # build so that GitHub has what dom0 runs; signed and pushed with the
    # bump key. Nothing new: build anyway
    if [ "$bump" = 1 ]; then
      (cd "$repo" && ${config.nix.package}/bin/nix flake update) >&2
      if ${pkgs.git}/bin/git -C "$repo" diff --quiet flake.lock; then
        echo "builder-build: inputs already up to date" >&2
      else
        ${pkgs.git}/bin/git -C "$repo" \
          -c user.name=builder-${vmRegistry.host or "vm"} \
          -c user.email=builder@nox \
          -c gpg.format=ssh \
          -c gpg.ssh.program=${pkgs.openssh}/bin/ssh-keygen \
          -c user.signingkey="$bumpkey" \
          commit --quiet -S -m update flake.lock >&2
        if ! GIT_SSH_COMMAND="$(git_ssh "$bumpkey")" \
          ${pkgs.git}/bin/git -C "$repo" push --quiet origin "HEAD:refs/heads/$branch" >&2; then
          echo "builder-build: push to $branch failed (bump-key.pub a deploy key with write access at GitHub? SSH repoUrl? $branch moved meanwhile: run again)" >&2
          exit 1
        fi
        echo "builder-build: pushed flake.lock to $branch @ $(${pkgs.git}/bin/git -C "$repo" rev-parse --short HEAD)" >&2
        trusted HEAD || { echo "builder-build: the bump commit does not verify (bump-signers), not building" >&2; exit 1; }
      fi
    fi

    # The previous system of this machine stops being a GC root before the
    # build (dom0 keeps it as a generation): otherwise old and new closure
    # have to fit side by side, and the store overlay ran full (xmg
    # 2026-10-29). Nix collects its paths during the build only when space
    # runs low (min-free below); paths the new system shares stay
    if [ "$machine" != installer-iso ]; then
      rm -f "${stateDir}/systems/$machine"
    fi

    # Progress through nom (nix-output-monitor) on stderr, which ssh brings
    # to dom0's terminal; the store path stays on stdout for dom0-update.
    # pipefail: a failed build fails here although nom exits 0
    out="$( {
      ${config.nix.package}/bin/nix build --print-out-paths \
        "''${link[@]}" \
        --log-format internal-json -v \
        "$repo#$attr" \
        2>&1 1>&3 | ${pkgs.nix-output-monitor}/bin/nom --json >&2
    } 3>&1 )"

    # The ISO leaves as a file stream, not into a store: no signature
    if [ "$machine" = installer-iso ]; then
      echo "$out"
      exit 0
    fi

    # Re-sign the whole closure: substituted paths only carry the cache's
    # signature, dom0 trusts nothing but this key
    ${config.nix.package}/bin/nix store sign --recursive --key-file "$key" "$out"

    echo "$out"
  '';
in
{
  imports = [
    ../modules/net-config.nix
    ../modules/common-config.nix
    ../modules/persistent-store-overlay.nix
    {
      options.nox.builder.repoUrl = lib.mkOption {
        type = lib.types.str;
        example = "https://github.com/<you>/<your-nox-config>";
        description = "Git URL of the config the builder builds (`nox.vms.builder.module` in the user's vms.nix). HTTPS for a public repo; for a private one the SSH URL (git@github.com:<you>/<config>.git) with the builder's own read-only deploy key (/var/lib/builder/deploy-key.pub, registered at GitHub as the repo's deploy key).";
      };
    }
  ];

  networking.hostName = "builder-vm";

  # GitHub's host key (api.github.com/meta, 2026-10-27) for the deploy key's
  # SSH fetches: checked strictly, never learned on first use
  programs.ssh.knownHosts."github.com".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

  services = {
    net-config = {
      enable = true;
      index = 25;
      mac = "00:00:00:00:00:19";
      # internet via the sys-net uplink (registry `nat = true`)
    };

    common-config = {
      enable = true;
      withDefaultPkgs = false;
    };

    persistentStoreOverlay = {
      enable = true;
      # registry `store.size` (registry/infra.nix, vms.nix may change it)
      overlaySize = reg.storeSize;
    };
  };

  microvm = {
    # The own closure (lower store disk) must be valid in the Nix DB. Otherwise
    # building a system that contains it (dom0's, which includes the builder)
    # makes Nix delete those paths as invalid; the overlay keeps that as
    # whiteouts and hides them on the next boot (lost sshd-keygen, 2026-10-06)
    registerClosure = true;
    hypervisor = "xen";
    volumes = [
      {
        # Repo checkout, out-links, signing key and the build directories
        image = "builder.img";
        mountPoint = stateDir;
        size = 40000;
      }
      {
        # Persistent journal (e.g. to see OOM kills after a restart)
        image = "log.img";
        mountPoint = "/var/log";
        size = 2048;
      }
    ];
    # Boots with registry `memory`, the RAM balancer grows it up to
    # `memoryMax` (defaults in registry/infra.nix, vms.nix may raise them)
    mem = reg.memoryMax;
    balloon = true;
    initialBalloonMem = reg.memory;
    vcpu = 8;
  };

  systemd = {
    tmpfiles.rules = [
      "d ${stateDir} 0755 user users -"
      "d ${stateDir}/systems 0755 user users -"
      "d ${stateDir}/build 0755 root root -"
    ]
    # Out-links survive reboots, /nix/var does not: re-register this
    # machine's as GC root so the persistent store overlay keeps its last
    # build (a build for another machine keeps its root until a reboot)
    ++
      lib.optional (vmRegistry.host or null != null)
        "L+ /nix/var/nix/gcroots/builder-${vmRegistry.host} - - - - ${stateDir}/systems/${vmRegistry.host}";

    services = {
      # Signing key, generated in the VM on first boot; only the public part
      # leaves it (vms/builder/signing-key-<machine>.pub, trusted by that dom0).
      # Same for the deploy key: an SSH key for a private config repo, read
      # only, registered at GitHub as that repo's deploy key (README "Builder"),
      # and the bump key: signs and pushes flake.lock (nox update), a deploy
      # key with write access, its public part in vms/builder/bump-signers
      builder-signing-key = {
        description = "Generate the builder's Nix signing key, deploy key and bump key";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        unitConfig.RequiresMountsFor = [ stateDir ];
        serviceConfig = {
          Type = "oneshot";
          User = "user";
          UMask = "0077";
        };
        path = [
          config.nix.package
          pkgs.openssh
        ];
        script = ''
          if [ ! -e ${stateDir}/signing-key ]; then
            nix key generate-secret --key-name builder-vm-1 > ${stateDir}/signing-key
            nix key convert-secret-to-public < ${stateDir}/signing-key > ${stateDir}/signing-key.pub
            chmod 644 ${stateDir}/signing-key.pub
          fi
          for k in deploy bump; do
            if [ ! -e ${stateDir}/$k-key ]; then
              ssh-keygen -q -t ed25519 -N "" -C builder-vm-$k -f ${stateDir}/$k-key
              chmod 644 ${stateDir}/$k-key.pub
            fi
          done
        '';
      };
    };
  };

  # nix.package (Lix, like dom0) comes from common-config
  nix.settings = {
    # RAM, not CPU, is the limit: the evaluator keeps its heap for the whole
    # build, and parallel mkfs.erofs runs (store images) ran out of memory
    # with "auto" (8). Each job still uses all cores. One job per 8 GB of
    # memoryMax: 16 GB → 2, 32 GB → 4
    max-jobs = lib.max 2 (reg.memoryMax / 8192);
    # Build directories on the volume instead of the RAM-backed root
    # (default /nix/var/nix/b is on the 2 GB tmpfs). Lix uses build-dir, not
    # the daemon's TMPDIR (the daemon is socket-activated per connection).
    build-dir = "${stateDir}/build";
    # The store overlay holds this machine's last closure; builder-build
    # unroots it before the next build, so GC during builds when space runs
    # low frees its paths. Room for the big store images (several GB each)
    min-free = reg.storeMinFree * 1024 * 1024;
    max-free = reg.storeMaxFree * 1024 * 1024;
    # Over HTTP/2 the many .narinfo queries share a few connections; on xmg
    # (2026-10-11) one stalled connection hung all of them for 300 s each
    # ("Operation too slow"). Separate HTTP/1.1 connections don't.
    http2 = false;
  };
  systemd.sockets.nix-daemon.unitConfig.RequiresMountsFor = [ stateDir ];

  # The balancer can only grow the VM as far as free Xen RAM allows; zram
  # absorbs eval peaks beyond that instead of the OOM killer. The size is
  # taken from the boot RAM (4096 MB), so 200 % = ~8 GB uncompressed.
  zramSwap = {
    enable = true;
    memoryPercent = 200;
  };

  environment.systemPackages = [
    builderBuild
    pkgs.git
  ];

  system.stateVersion = "26.05";
}
