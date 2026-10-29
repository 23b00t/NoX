# The disposables of VMs with `hasDisposable` (`nox disp --from <vm>`):
# `disp-<vm>` is the VM's entry with its role, apps, module and fields, but
# empty on every start (`disposable`), with the label of `disp`, its own
# index (+ 100) and short alias (d<short>). Added after the module
# evaluation (nox.vms can't add entries derived from itself). Its apps are
# installed in it but give no desktop entries (legacy.nix: `disposableOf`).
{ lib }:
nox:
let
  inherit (nox) vms;
  bases = lib.filterAttrs (_: v: v.hasDisposable == true) vms;
  taken = lib.mapAttrsToList (_: v: v.index) (vms // nox.images);
  shorts = lib.filter (s: s != null) (lib.mapAttrsToList (_: v: v.short) (vms // nox.images));

  mkDisposable =
    name: v:
    let
      dname = "disp-${name}";
      index = v.index + 100;
      short = if v.short == null then null else "d${v.short}";
      fail = msg: throw "nox.vms.${name}.hasDisposable: ${msg}";
    in
    if v.role == null then
      fail "needs a role"
    else if v.storeGroup == null then
      fail "a VM with an own store image (storeGroup = null) is not supported yet"
    else if vms ? ${dname} then
      fail "${dname} exists already"
    else if index > 252 then
      fail "index ${toString v.index} + 100 is above 252"
    else if builtins.elem index taken then
      fail "index ${toString index} (${toString v.index} + 100) is taken"
    else if short != null && builtins.elem short shorts then
      fail "short alias ${short} is taken"
    else
      lib.nameValuePair dname (
        v
        // {
          inherit index short;
          label = vms.disp.label or null;
          disposable = true;
          hasDisposable = false;
          disposableOf = name;
          backup = false;
          autostart = false;
          # its own (wiped) home, never the base's
          home = v.home // {
            image = null;
          };
        }
      );
in
lib.mapAttrs' mkDisposable bases
