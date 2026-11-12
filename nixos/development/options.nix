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
      (`journalctl -t dom0-update`). The builder VMs' own timing lines
      (`builder-build`, `builder-images`) are not affected.
    '';
  };
}
