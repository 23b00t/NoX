# nox.dev: debugging and measuring aids for NoX itself, not part of the
# product. `nox.dev.enable = true` turns all of them on; each can be turned
# off on its own (`nox.dev.<aid>.enable = false`). Declarations only, so
# the options reference (nix/options-doc.nix) can read them.
{ lib, config, ... }:
let
  cfg = config.nox.dev;
  aid =
    description:
    lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      defaultText = lib.literalExpression "config.nox.dev.enable";
      inherit description;
    };
in
{
  options.nox.dev = {
    enable = lib.mkEnableOption "all of NoX's debugging and measuring aids (`nox.dev.*`)";

    timing.enable = aid ''
      Boot and RAM timing in the journal: dom0 memory samples (unit
      `nox-mem`), session start and new windows (user unit `nox-timing`),
      the end of the login tabs; the `nox-timing [-b N] [--mem]` report
      reads one boot.
    '';

    buildTiming.enable = aid ''
      `dom0-update` (`nox update`) prints the duration of each step
      ("dom0-update: timing …") and logs it to the journal
      (`journalctl -t dom0-update`). Without it `nox update` also hides the
      builder VMs' timing lines (`builder-build`, `builder-images`) in its
      output; the builders' own journals keep them (`journalctl -t
      builder-build` or `-t builder-images` in the VM).
    '';

    xenTrace.enable = aid ''
      Xen trace logging and a report of the boot entries on rebuild:
      `virtualisation.xen.trace` (Xen parameters `loglvl=all
      guest_loglvl=all`, xenstored and xenconsoled trace) and
      `virtualisation.xen.boot.builderVerbosity = "info"` (diff of the
      changed generations when the boot entries are written). The guest
      consoles are then written to dom0's disk in `/var/log/xen/console/`,
      including what is typed and printed in a console login; xenstored logs
      at debug level to `/var/log/xen/xenstored.log`. Turn it on only on test
      and development systems. The Xen parameters are boot parameters: a
      change takes effect after the rebuild and a reboot (xenconsoled and
      xenstored read the trace variables when they start). Turning it off
      deletes no existing logs.
    '';
  };
}
