# dom0-update (v2.4): dom0 pulls its system from the builder VM instead of
# evaluating and building itself. The builder signs the whole closure; dom0's
# nix-daemon only accepts it with a valid signature from the builder key
# (registry `builderKeys`/signing-key-<machine>.pub: every machine has its own builder
# VM and key). Pull only: the builder never gets access to dom0.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  cfg = config.services.dom0-update;
  builderIp = vmRegistry.byName.builder.ip;
  keyFile = vmRegistry.builderKeys + "/signing-key-${config.networking.hostName}.pub";
  keyText = if builtins.pathExists keyFile then lib.trim (builtins.readFile keyFile) else "";
  # An empty file (e.g. from a failed `ssh … > signing-key.pub`) counts as no key
  builderKey = if keyText != "" then keyText else null;
  # The sys builder's key name (builder-vm-1): marks its own builds
  signKeyName =
    if builderKey != null then lib.head (lib.splitString ":" builderKey) else "builder-vm-1";
  # The image key (signs the store image manifest, ssh-keygen -Y)
  imageKeyFile = vmRegistry.builderKeys + "/image-key-${config.networking.hostName}.pub";
  # Group builders' image keys from image-key-<builder>-<machine>.pub next to it
  fileImageKeys = lib.listToAttrs (
    lib.concatMap (
      b:
      let
        f = vmRegistry.builderKeys + "/image-key-${b}-${config.networking.hostName}.pub";
      in
      lib.optional (b != "builder" && builtins.pathExists f) (
        lib.nameValuePair b (lib.trim (builtins.readFile f))
      )
    ) (lib.unique (lib.attrValues (vmRegistry.storeGroupBuilders or { })))
  );
  imageKeys =
    fileImageKeys
    // cfg.imageKeys
    // lib.optionalAttrs (cfg.imageKey != null) { builder = cfg.imageKey; };
  groupBuilderVms = lib.filter (
    vm:
    vm.name != "builder"
    && builtins.elem vm.name (lib.attrValues (vmRegistry.storeGroupBuilders or { }))
  ) vmRegistry.vms;

  # Builder output (nom on stderr) reaches dom0's terminal only through this
  # positive-list filter: colors and cursor movement stay; OSC 52
  # (clipboard), titles and queries (the terminal's answer would go back to
  # the builder) are dropped (nox-cli src/term_filter.rs)
  termFilter = "${config.programs.nox.package}/bin/nox term-filter";

  dom0Update = pkgs.writeShellScriptBin "dom0-update" ''
    set -euo pipefail

    usage() {
      cat <<EOF >&2
    Usage: dom0-update [--bump] [--switch] [--machine <name>] [--branch <branch>]
           dom0-update --iso <vm> [--branch <branch>]

    Builds the system on the builder VM, copies the signed closure and
    activates it for the next boot (default) or right away (--switch).
    --bump: the builder updates the flake inputs first and pushes
    flake.lock as a signed commit "update" (nox update).
    --iso <vm>: builds the config's installer ISO instead and copies it
    from the builder straight to <vm> (~/Incoming/builder/nox-installer.iso
    there; started if it is off), nothing goes through dom0's store.
    Group builders (nox.builders, the images of their store groups):
    --parallel <n>: how many run at the same time (their output then goes
    to ~/.local/state/nox/update-<builder>.log, the terminal gets the
    timing and error lines); --builder <name>: only this one (repeatable;
    the update stops before activating if images are still missing).
    --max-jobs <n>, --cores <n>: Nix max-jobs/cores of every builder for
    this run.
    Defaults: --machine ${cfg.machine} --branch ${cfg.branch} --parallel ${toString cfg.parallel}${
      lib.optionalString (cfg.maxJobs != null) " --max-jobs ${toString cfg.maxJobs}"
    }${lib.optionalString (cfg.cores != null) " --cores ${toString cfg.cores}"}
    EOF
      exit 1
    }

    action=boot
    bump=()
    iso_vm=""
    machine=${lib.escapeShellArg cfg.machine}
    branch=${lib.escapeShellArg cfg.branch}
    parallel=${toString cfg.parallel}
    max_jobs=${lib.optionalString (cfg.maxJobs != null) (toString cfg.maxJobs)}
    cores=${lib.optionalString (cfg.cores != null) (toString cfg.cores)}
    only=()
    group_opts=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --switch) action=switch ;;
        --bump) bump=(--bump) ;;
        --iso) [ $# -ge 2 ] || usage; action=iso; iso_vm="$2"; shift ;;
        --machine) [ $# -ge 2 ] || usage; machine="$2"; shift ;;
        --branch) [ $# -ge 2 ] || usage; branch="$2"; shift ;;
        --parallel) [[ ''${2:-} =~ ^[1-9][0-9]?$ ]] || usage; parallel="$2"; group_opts=1; shift ;;
        --max-jobs) [[ ''${2:-} =~ ^[1-9][0-9]{0,2}$ ]] || usage; max_jobs="$2"; shift ;;
        --cores) [[ ''${2:-} =~ ^[0-9]{1,3}$ ]] || usage; cores="$2"; shift ;;
        # builder-desktop or desktop
        --builder) [[ ''${2:-} =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage; only+=("builder-''${2#builder-}"); group_opts=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
      esac
      shift
    done
    # The ISO is built from the branch as it is, by the builder alone (no
    # group builders: --parallel/--builder mean nothing there)
    [ "$action" != iso ] || [ "''${#bump[@]}" = 0 ] || usage
    [ "$action" != iso ] || [ "$group_opts" = 0 ] || usage
    nixjobs=()
    [ -z "$max_jobs" ] || nixjobs+=(--max-jobs "$max_jobs")
    [ -z "$cores" ] || nixjobs+=(--cores "$cores")
    # The group builders' memoryMax (MB), for the RAM check of --parallel
    declare -A memoryMax=(${
      lib.concatMapStrings (vm: " [${vm.name}]=${toString (vm.memoryMax or 8192)}") groupBuilderVms
    } )

    ${lib.optionalString (builderKey == null) ''
      echo "dom0-update: vms/builder/signing-key-${config.networking.hostName}.pub is missing, dom0 does not trust the builder yet" >&2
      exit 1
    ''}

    # One run at a time: two would share the builder (one stops it under
    # the other), its checkout, the logs and the pending mark
    exec 9>"''${XDG_RUNTIME_DIR:-/tmp}/dom0-update.lock"
    ${pkgs.util-linux}/bin/flock -n 9 || {
      echo "dom0-update: another run is in progress" >&2
      exit 1
    }

    # Ask for the sudo password now, not after the build, and keep the
    # timestamp fresh meanwhile. Without a terminal (unattended runs) rely on
    # NOPASSWD rules for the commands below.
    if [ -t 0 ]; then
      sudo -v
      while sleep 60; do sudo -n -v 2>/dev/null || exit; done &
      keepalive=$!
    fi

    # Builder VMs this run started: stopped again when it fails (on success
    # each one is stopped after its step; builder-trust.md 13.6)
    started=()
    cleanup() {
      local rc=$? vm
      if [ "$rc" != 0 ]; then
        for vm in "''${started[@]}"; do
          systemctl is-active --quiet "microvm@$vm" || continue
          echo "dom0-update: failed, stopping $vm" >&2
          sudo systemctl stop "microvm@$vm" || true
        done
      fi
      # The pending mark of the new system (nox-image gc), when the run
      # ends before it became a generation
      [ -z "''${pending:-}" ] || sudo "$mark" pending -d "$pending" || true
      rm -f "''${signed:-}"
      [ -z "''${keepalive:-}" ] || kill "$keepalive" 2>/dev/null || true
    }
    trap cleanup EXIT
    # Ctrl-C and the like: through cleanup too (an untrapped signal skips
    # the EXIT trap)
    trap 'exit 130' INT TERM HUP

    # Free space for the builders' volumes and the fetched images: below
    # minFree the builders could fill dom0's disk (builder-trust.md 13.7)
    for d in /var/lib/microvms /var/lib/nox/images; do
      [ -d "$d" ] || continue
      avail="$(df --output=avail -BG "$d" | tail -n 1 | tr -dc 0-9)"
      if [ "$avail" -lt ${toString cfg.minFree} ]; then
        echo "dom0-update: only $avail GB free for $d, at least ${toString cfg.minFree} GB needed (services.dom0-update.minFree); free space first (nox gc, the builders' store volumes)" >&2
        exit 1
      fi
    done

    unexpected() {
      printf 'dom0-update: unexpected builder output: %q\n' "$1" >&2
      exit 1
    }
    # stdout of a builder command: its last line; its stderr goes to the
    # terminal through the filter
    from_builder() {
      { ssh ${builderIp} "$@" 2>&1 >&3 3>&- |
        ${termFilter} >&2 3>&-; } 3>&1 | tail -n 1
    }

    # The builder doesn't autostart: start it and wait for SSH (over vchan).
    # Started here = stopped again afterwards.
    started_builder=0
    if ! systemctl is-active --quiet microvm@builder; then
      echo "dom0-update: starting the builder VM" >&2
      started+=(builder)
      sudo systemctl start microvm@builder
      started_builder=1
    fi
    # The ISO's target VM: started now, so it boots while the builder builds;
    # it stays running afterwards (the ISO is in it)
    if [ "$action" = iso ] && ! systemctl is-active --quiet "microvm@$iso_vm"; then
      echo "dom0-update: starting $iso_vm" >&2
      sudo systemctl start "microvm@$iso_vm"
    fi
    for _ in $(seq 120); do
      ssh -o ConnectTimeout=5 ${builderIp} true >/dev/null 2>&1 && break
      if systemctl is-failed --quiet microvm@builder; then
        echo "dom0-update: the builder VM failed to start (journalctl -u microvm@builder)" >&2
        exit 1
      fi
      sleep 2
    done

    # The installer ISO: built in the builder's store, streamed from there
    # through the broker to the VM like `nox copy builder <vm>` (dom0's own
    # call: the copy policy doesn't ask), then deleted in the builder. The
    # broker gives the manifest 10 s, so the stream starts only after the build
    if [ "$action" = iso ]; then
      out="$(from_builder builder-build "''${nixjobs[@]}" --iso "$branch")"
      [[ "$out" =~ ^/nix/store/[0-9a-z]{32}-nox-installer\.iso$ ]] || unexpected "$out"
      # The VM may still be booting: wait until its rpc side answers (a
      # side-effect-free `send list` of a missing path answers "error: …
      # not found"; while booting the relay drops the call without one)
      for _ in $(seq 120); do
        [ -n "$(printf 'list\n%s\0' .nox-ready | nox-rpc --dom0 send "$iso_vm" 2>/dev/null)" ] && break
        sleep 1
      done
      echo "dom0-update: copying the ISO to $iso_vm" >&2
      answer="$(ssh ${builderIp} "nox-pack $out/iso/*.iso" 2> >(${termFilter} >&2) |
        nox-rpc --broker copy "$iso_vm" as=builder)" || true
      echo "$answer"
      if [[ "$answer" != ok* ]]; then
        echo "dom0-update: copy to $iso_vm failed; the ISO stays in the builder's store until its GC (another --iso doesn't build it again)" >&2
        exit 1
      fi
      ssh ${builderIp} nix store delete "$out" >/dev/null 2>&1 ||
        echo "dom0-update: could not delete $out in the builder, its GC takes it" >&2
      echo "dom0-update: ISO in $iso_vm: ~/Incoming/builder/nox-installer.iso" >&2
    else
      # Runs as the calling user (ssh config/key for ${builderIp}); the nix-daemon
      # verifies the builder signature when the paths are added
      # Duration of each step on stderr and in the journal
      # (journalctl -t dom0-update); the builder's own steps are in its
      # journal (journalctl -t builder-build)
      t0=$SECONDS
      t_start=$SECONDS
      timing() {
        local now=$SECONDS
        echo "dom0-update: timing $1 $((now - t0)) s" >&2
        ${pkgs.util-linux}/bin/logger -t dom0-update "timing $machine $1 $((now - t0)) s" || true
        t0=$now
      }
      out="$(from_builder builder-build "''${bump[@]}" "''${nixjobs[@]}" "$machine" "$branch")"
      [[ "$out" =~ ^/nix/store/[0-9a-z]{32}-nixos-system-[A-Za-z0-9._+-]+$ ]] || unexpected "$out"
      timing builder

      echo "dom0-update: copying $out" >&2
      # stderr carries the builder's nix-daemon output too: filtered
      ${config.nix.package}/bin/nix copy --from ssh-ng://${builderIp} "$out" \
        2> >(${termFilter} >&2)
      timing copy

      # What only the builder vouches for (no Hydra signature): own builds,
      # Cachix paths, the store images. Summary and the largest here, the
      # whole list in ~/.cache/nox/builder-only-paths
      list="''${XDG_CACHE_HOME:-$HOME/.cache}/nox/builder-only-paths"
      mkdir -p "''${list%/*}"
      ${config.nix.package}/bin/nix path-info -r -s --sigs "$out" |
        ${pkgs.gawk}/bin/awk '!/cache\.nixos\.org-1:/ { print $2 "\t" $1 }' |
        sort -rn > "$list"
      ${pkgs.gawk}/bin/awk -F '\t' '
        { n++; s += $1; if ($2 ~ /-microvm-store-disk\./) { i++; is += $1 } }
        END { printf "dom0-update: %d paths without a Hydra signature, %.2f GiB (%d store images, %.2f GiB)\n", n, s / 2^30, i, is / 2^30 }
      ' "$list" | tee >(${pkgs.util-linux}/bin/logger -t dom0-update) >&2
      ${pkgs.gawk}/bin/awk -F '\t' '$2 !~ /-microvm-store-disk\./ && n++ < 15 { printf "  %8.1f MiB  %s\n", $1 / 2^20, $2 }' "$list" >&2
      echo "dom0-update: full list in $list" >&2

      # Store images as files (dom0/store-images.nix): the new system's
      # nox-image fetches the ones it expects and dom0 doesn't have yet,
      # each from its own builder, checked against that builder's signed
      # manifest and their sha256. dom0's nix-daemon never sees them
      ni="$out/sw/bin/nox-image"
      n="$("$ni" missing "$out" | wc -l)"
      # Until the profile is set, $out is no generation: the mark keeps
      # nox-image gc (nox gc) from deleting what is fetched meanwhile. Set
      # with the running system's nox-image, whose gc reads it ($ni may be
      # older)
      mark=/run/current-system/sw/bin/nox-image
      sudo "$mark" pending "$out"
      pending=$out
      "$ni" fetch "$out" builder "$machine"
      timing "images of the builder"

      # Images of other builders (nox.storeGroups.<g>.builder, variant B):
      # their derivations come from the sys builder (it evaluated them) and
      # go to that builder, which builds without a checkout or evaluation
      # (builder-trust.md 3.2, 3.6). The derivations carry no CA field in
      # the sys builder's store; builder-build signs them with its key, which
      # dom0 and the group builders trust, and both copies check that
      # signature (builder-trust.md 13.1, 14.2). The sys builder's own
      # builds (non-Hydra paths of the new system, signed by it) go along,
      # so the app builder doesn't build them again (3.7)
      mapfile -t others < <("$ni" missing "$out" | ${pkgs.gawk}/bin/awk '$3 != "builder" { print $3 }' | sort -u)
      # --builder: only these (the check before activating catches what is
      # still missing)
      if [ "''${#only[@]}" -gt 0 ]; then
        declare -A want=()
        for b in "''${only[@]}"; do want[$b]=1; done
        picked=()
        for b in "''${others[@]}"; do
          [ -z "''${want[$b]:-}" ] || { picked+=("$b"); unset "want[$b]"; }
        done
        for b in "''${!want[@]}"; do
          echo "dom0-update: $b has no missing images" >&2
        done
        others=("''${picked[@]}")
      fi
      declare -A handover=()
      alldrvs=()
      for b in "''${others[@]}"; do
        [[ $b =~ ^[a-z0-9-]+$ ]] || unexpected "$b"
        mapfile -t pairs < <("$ni" drvs "$out" "$b")
        handover[$b]="''${pairs[*]}"
        alldrvs+=("''${pairs[@]#*=}")
        ${config.nix.package}/bin/nix copy --derivation --from ssh-ng://${builderIp} \
          "''${pairs[@]#*=}" 2> >(${termFilter} >&2)
      done
      # nix copy skips derivations dom0 already has (from earlier runs,
      # without this signature): their signature comes separately, or the
      # copy to the group builder rejects them. Once for all groups (the
      # closures overlap)
      if [ "''${#alldrvs[@]}" -gt 0 ]; then
        ${config.nix.package}/bin/nix store copy-sigs --substituter ssh-ng://${builderIp} \
          -r --derivation "''${alldrvs[@]}" >/dev/null 2> >(${termFilter} >&2)
      fi
      if [ "$started_builder" = 1 ] && [ "''${#others[@]}" -gt 0 ]; then
        # RAM for the app builders
        sudo systemctl stop microvm@builder
        started_builder=0
      elif [ "''${#others[@]}" -gt 0 ]; then
        # Started by someone else: left running, but it holds its RAM
        # through the group phase (builder-trust.md 14.3)
        echo "dom0-update: warning: the builder VM was already running and stays on; group builders may not get memory to start (stop it first: sudo systemctl stop microvm@builder)" >&2
      fi
      # Only paths with the sys builder's signature: the group builders
      # trust that key, a single path without it would abort the whole copy.
      # Once for all of them (sorted: run_builder intersects it per group)
      signed="$(mktemp)"
      # The ones run_builder starts (in a subshell when parallel): noted
      # here for cleanup
      for b in "''${others[@]}"; do
        systemctl is-active --quiet "microvm@$b" || started+=("$b")
      done
      if [ "''${#others[@]}" -gt 0 ]; then
        cut -f2 "$list" | xargs -r ${config.nix.package}/bin/nix path-info --sigs |
          ${pkgs.gawk}/bin/awk -v k=${lib.escapeShellArg "${signKeyName}:"} 'index($0, k) { print $1 }' |
          sort -u > "$signed"
      fi

      # One group builder: start, hand over, build, fetch, stop
      run_builder() {
        local b=$1 started_b=0 pairs
        read -r -a pairs <<< "''${handover[$b]}"
        if ! systemctl is-active --quiet "microvm@$b"; then
          echo "dom0-update: starting $b" >&2
          sudo systemctl start "microvm@$b"
          started_b=1
        fi
        local up=0
        for _ in $(seq 120); do
          ssh -o ConnectTimeout=5 "$b-vm" true >/dev/null 2>&1 && { up=1; break; }
          # Not started at all (e.g. no memory for the domain): no point
          # in waiting out the loop
          if systemctl is-failed --quiet "microvm@$b"; then
            echo "dom0-update: $b failed to start (journalctl -u microvm@$b)" >&2
            return 1
          fi
          sleep 2
        done
        [ "$up" = 1 ] || { echo "dom0-update: $b does not answer over SSH" >&2; return 1; }
        ${config.nix.package}/bin/nix copy --derivation --to "ssh-ng://$b-vm" \
          "''${pairs[@]#*=}" 2> >(${termFilter} >&2)
        # Of those only what this group's derivations build on (outputs in
        # their closure that dom0 has: wprs, nox-rpc, nox-relay …), not the
        # whole dom0 closure (builder-trust.md 13.2)
        comm -12 "$signed" <(${config.nix.package}/bin/nix-store -q --requisites --include-outputs \
          "''${pairs[@]#*=}" | sort -u) |
          xargs -r ${config.nix.package}/bin/nix copy --to "ssh-ng://$b-vm" \
          2> >(${termFilter} >&2) ||
          echo "dom0-update: could not hand the builder's own builds to $b, it builds them itself" >&2
        { ssh "$b-vm" builder-images "''${nixjobs[@]}" "$machine" "''${pairs[@]}" 2>&1 >&3 3>&- |
          ${termFilter} >&2 3>&-; } 3>&1 | tail -n 1 >/dev/null
        "$ni" fetch "$out" "$b" "$machine"
        timing "images of $b"
        if [ "$started_b" = 1 ]; then
          sudo systemctl stop "microvm@$b"
        fi
      }

      if [ "$parallel" -le 1 ] || [ "''${#others[@]}" -le 1 ]; then
        for b in "''${others[@]}"; do
          run_builder "$b"
        done
      else
        # RAM: n builders at their memoryMax next to the running VMs
        need=0
        for b in "''${others[@]:0:$parallel}"; do
          need=$((need + ''${memoryMax[$b]:-8192}))
        done
        free="$(sudo -n ${pkgs.xen}/bin/xl info free_memory 2>/dev/null || true)"
        if [[ $free =~ ^[0-9]+$ ]] && [ "$need" -gt "$free" ]; then
          echo "dom0-update: warning: $parallel builders may grow to $need MB, Xen has $free MB free (ballooning may cover it; --parallel 1 if builds fail)" >&2
        fi
        logs="''${XDG_STATE_HOME:-$HOME/.local/state}/nox"
        status="$(mktemp -d)"
        mkdir -p "$logs"
        echo "dom0-update: ''${#others[@]} group builders, $parallel at a time; logs in $logs/update-<builder>.log" >&2
        # Own list of the builder jobs: `jobs` and a bare `wait` would count
        # and wait for the sudo keepalive too (builder-trust.md 13.1)
        pids=()
        for b in "''${others[@]}"; do
          while :; do
            running=0
            for p in "''${pids[@]}"; do
              ! kill -0 "$p" 2>/dev/null || running=$((running + 1))
            done
            [ "$running" -ge "$parallel" ] || break
            wait -n "''${pids[@]}" || true
          done
          : > "$logs/update-$b.log"
          # The full (filtered) output to the log; to the terminal only
          # the lines that say something, without escape sequences
          (
            set +e
            (set -e; run_builder "$b")
            rc=$?
            echo "$rc" > "$status/$b"
            # A failed builder gives its RAM back now, not only in cleanup
            # after the other jobs (the next one may need it to start)
            if [ "$rc" != 0 ] && [[ " ''${started[*]} " == *" $b "* ]] &&
              systemctl is-active --quiet "microvm@$b"; then
              echo "dom0-update: $b failed, stopping it" >&2
              sudo systemctl stop "microvm@$b" || true
            fi
          ) </dev/null 2> >(tee -a "$logs/update-$b.log" |
            ${pkgs.gnused}/bin/sed -u -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' |
            grep -a --line-buffered -E '^(dom0-update|nox-image|builder-images: timing)|(^|[[:space:]])(error|warning):' |
            grep -av --line-buffered -e '┃' -e '┗' |
            ${pkgs.gnused}/bin/sed -u -e "s/^/[$b] /" >&2) &
          pids+=("$!")
        done
        for p in "''${pids[@]}"; do
          wait "$p" || true
        done
        # The builders' timing counts from the start of this phase; the
        # next step from its end
        t0=$SECONDS
        failed=()
        for b in "''${others[@]}"; do
          [ "$(cat "$status/$b" 2>/dev/null)" = 0 ] || failed+=("$b")
        done
        rm -rf "$status"
        if [ "''${#failed[@]}" -gt 0 ]; then
          echo "dom0-update: failed: ''${failed[*]} (logs in $logs), not activated" >&2
          exit 1
        fi
      fi
      echo "dom0-update: $n new store images" >&2

      # Every image the new system expects is here, else it isn't activated
      # (--builder, a builder that failed)
      mapfile -t still < <("$ni" missing "$out")
      if [ "''${#still[@]}" -gt 0 ]; then
        printf 'dom0-update: still missing: %s\n' "''${still[@]}" >&2
        echo "dom0-update: not activated" >&2
        exit 1
      fi

      if [ "$started_builder" = 1 ]; then
        # RAM for the VMs the switch restarts (without group builders the
        # builder still runs here, ballooned up by the build)
        sudo systemctl stop microvm@builder
        started_builder=0
      fi
      sudo ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set "$out"
      sudo "$mark" pending -d "$out"
      pending=""
      sudo "$out/bin/switch-to-configuration" "$action"
      timing "$action"
      t0=$t_start
      timing total
      echo "dom0-update: $action done ($out)" >&2
    fi

    if [ "$started_builder" = 1 ]; then
      echo "dom0-update: stopping the builder VM again" >&2
      sudo systemctl stop microvm@builder
    fi
  '';
in
{
  options.services.dom0-update = {
    enable = lib.mkEnableOption "pulling the dom0 system from the builder VM";

    machine = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "nixosConfiguration the builder builds for this dom0.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = cfg.machine;
      defaultText = lib.literalExpression "config.services.dom0-update.machine";
      description = "Git branch the builder fetches.";
    };

    imageKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if builtins.pathExists imageKeyFile then lib.trim (builtins.readFile imageKeyFile) else null;
      defaultText = lib.literalExpression "vms/builder/image-key-<host>.pub";
      example = "ssh-ed25519 AAAA… builder-vm-image";
      description = "Public part of the builder's image key (/var/lib/builder/image-key.pub): dom0-update only takes the builder's store images listed in a manifest signed with it (namespace nox-image). Same as `imageKeys.builder`.";
    };

    parallel = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 1;
      description = "How many group builders (nox.builders) build at the same time; `nox update --parallel` overrides it. Each may grow to its `memoryMax`: dom0-update warns when they don't fit into Xen's free memory.";
    };

    minFree = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = "GB that must be free for /var/lib/microvms and /var/lib/nox/images before an update starts: the builders' store volumes grow on dom0's disk while they build, the fetched images land there. 0 turns the check off.";
    };

    maxJobs = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 1 999);
      default = null;
      description = "Nix `max-jobs` of every builder (the builder and the group builders) during an update, instead of their own `nix.settings`; `nox update --max-jobs` overrides it. null: each builder's own (nox.builders.<name>.maxJobs, one per 8 GB of memoryMax).";
    };

    cores = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 0 999);
      default = null;
      description = "Nix `cores` per job of every builder during an update (0: all); `nox update --cores` overrides it. null: each builder's own.";
    };

    imageKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        builder-desktop = "ssh-ed25519 AAAA… builder-desktop-image";
      };
      description = "Image keys of further builders (nox.storeGroups.<g>.builder), by builder VM name: dom0 takes an image only with the key of the builder its group names. Default: the files `image-key-<builder>-<machine>.pub` next to the signing key (registry `builderKeys`).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ dom0Update ];

    # Additive while dom0 still has internet (until v2.5): the existing
    # substituters stay, the builder key is trusted on top
    nix.settings.trusted-public-keys = lib.optional (builderKey != null) builderKey;

    # ssh-keygen allowed signers for the image manifests (nox-image fetch):
    # one principal per builder VM, its name
    environment.etc."nox/image-signers" = lib.mkIf (imageKeys != { }) {
      text = lib.concatStrings (
        lib.mapAttrsToList (name: key: "${name} namespaces=\"nox-image\" ${key}\n") imageKeys
      );
    };

    # The group builders, for nox update/rebuild --builder (nox-cli checks
    # the names)
    programs.nox.registry.builders = map (vm: vm.name) groupBuilderVms;
  };
}
