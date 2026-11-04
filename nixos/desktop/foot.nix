# foot, dom0's terminal (/etc/xdg/foot/foot.ini). dom0 runs no foot server:
# foot's client and server entries are hidden (they win over the package's
# own .desktop files)
{
  pkgs,
  lib,
  config,
  ...
}:
let
  theme = import ./theme.nix {
    inherit lib;
    inherit (config.nox.desktop) theme;
  };
  # locked-title: programs in dom0's terminal can't set a title like
  # "[vault] …" and get that VM's border in niri
  # osc52 = disabled: output of untrusted programs (builder logs,
  # `xl console`) can neither write nor read dom0's clipboard
  settings = lib.recursiveUpdate theme.foot {
    main.locked-title = "yes";
    security.osc52 = "disabled";
  };
  hidden = name: {
    inherit name;
    exec = "false";
    noDisplay = true;
  };
in
{
  environment.systemPackages = [ pkgs.foot ];
  environment.etc."xdg/foot/foot.ini".source =
    (pkgs.formats.ini { listsAsDuplicateKeys = true; }).generate "foot.ini"
      settings;
  nox.desktopEntries = {
    footclient = hidden "Foot Client";
    foot-server = hidden "Foot Server";
  };
}
