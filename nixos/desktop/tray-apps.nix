# Tray apps per VM, started with the session and again by `vm-tray <vm>`
# after that VM is (re)started (manage-vms): the VMs' apps with
# `tray = true` (registry `apps`; sys-net's nm-applet, too).
# { <vm> = [ [ binary args… ] … ]; }
{ lib, vmRegistry }:
let
  trayOf =
    a:
    [ a.binary ] ++ (a.args or [ ]) ++ (a.trayArgs or [ ]) ++ lib.optional a.x11 "--ozone-platform=x11";
  trayApps = lib.listToAttrs (
    lib.concatMap (
      vm:
      let
        apps = lib.filter (a: a.tray) (vm.apps or [ ]);
      in
      lib.optional (apps != [ ]) {
        inherit (vm) name;
        value = map trayOf apps;
      }
    ) vmRegistry.vms
  );
in
trayApps
