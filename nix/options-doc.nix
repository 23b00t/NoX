# Reference of NoX's config options (nox.vms, nox.images, nox.roles,
# nox.apps, nox.infra, nox.storeGroups, nox.network, nox.desktop,
# nox.desktopEntries, dom0's nox.unfree) as Markdown: `nix build
# .#options-doc`, copied to docs/options.md. Only the option declarations
# are evaluated (no NixOS system): the registry schema and dom0's modules
# that declare nox options.
{
  lib,
  pkgs,
  nixosOptionsDoc,
  runCommand,
}:
let
  eval = lib.evalModules {
    modules = [
      ../nixos/registry/vms.nix
      ../nixos/desktop
      ../nixos/dom0/tools/desktop-entries.nix
      ../nixos/dom0/unfree.nix
      {
        # The desktop modules also set NixOS options, which don't exist here
        _module.check = false;
        _module.args = { inherit pkgs; };
      }
    ];
    specialArgs.host = null;
  };
  doc = nixosOptionsDoc {
    options = builtins.removeAttrs eval.options [ "_module" ];
    # Links to the declarations relative to the repo
    transformOptions =
      opt:
      opt
      // {
        declarations = map (
          d:
          let
            s = toString d;
            rel = lib.removePrefix (toString ../. + "/") s;
          in
          {
            name = rel;
            # docs/options.md: links relative to docs/
            url = "../" + rel;
          }
        ) opt.declarations;
      };
  };
  # What NoX brings: its roles with their defaults, the app catalog and the
  # infrastructure VMs
  inherit (eval.config) nox;
  fmt = v: if builtins.isString v then v else builtins.toJSON v;
  catalog = lib.concatStringsSep "\n" (
    [
      "## Roles"
      ""
      "| Role | Description | Defaults |"
      "| --- | --- | --- |"
    ]
    ++ lib.mapAttrsToList (
      n: r:
      "| `${n}` | ${r.description} | ${
        lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "`${k} = ${fmt v}`") r.defaults)
      } |"
    ) nox.roles
    ++ [
      ""
      "## App catalog"
      ""
      "| App | Package | Name |"
      "| --- | --- | --- |"
    ]
    ++ lib.mapAttrsToList (
      n: a:
      "| `${n}` | ${
        if a.package == null then "(the VM's module)" else "`${a.package}`"
      } | ${toString a.name} |"
    ) nox.apps
    ++ [
      ""
      "## Infrastructure VMs"
      ""
      "On by default: ${
        lib.concatStringsSep ", " (
          lib.mapAttrsToList (n: _: "`${n}`") (lib.filterAttrs (_: i: i.enable) nox.infra)
        )
      }; with `nox.infra.<name>.enable`: ${
        lib.concatStringsSep ", " (
          lib.mapAttrsToList (n: _: "`${n}`") (lib.filterAttrs (_: i: !i.enable) nox.infra)
        )
      }."
      ""
    ]
  );
in
runCommand "nox-options.md" { } ''
  {
    echo "# NoX options"
    echo
    echo "Generated from the option declarations (\`nix build .#options-doc\`); do not edit."
    echo
    cat ${builtins.toFile "nox-catalog.md" catalog}
    echo
    echo "## Options"
    echo
    sed "s/^## /### /" ${doc.optionsCommonMark}
  } > $out
''
