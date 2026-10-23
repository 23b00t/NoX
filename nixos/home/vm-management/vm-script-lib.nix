{
  vmUserDefault ? "user",
}:
let
  vmUser = vm: vm.user or vmUserDefault;

  vmPatterns =
    vm:
    if vm.short != null && vm.short != vm.name then
      "\"${vm.name}\"|\"${vm.short}\""
    else
      "\"${vm.name}\"";

  vmList =
    vms:
    builtins.concatStringsSep "\n" (
      map (
        vm:
        if vm.short != null && vm.short != vm.name then
          "  ${vm.name} (${vm.short})"
        else
          "  ${vm.name}"
      ) vms
    );

  vmCaseBlock =
    {
      vms,
      assignments,
    }:
    builtins.concatStringsSep "\n" (
      map (
        vm:
        let
          assignmentLines = builtins.concatStringsSep "\n" (
            map (
              assignment:
              let
                value =
                  if assignment ? valueFrom then
                    assignment.valueFrom vm
                  else if assignment ? attr && builtins.hasAttr assignment.attr vm then
                    builtins.getAttr assignment.attr vm
                  else
                    assignment.default or "";
              in
              "        ${assignment.shellName}=\"${toString value}\""
            ) assignments
          );
        in
        "      ${vmPatterns vm})\n"
        + assignmentLines
        + "\n        ;;"
      ) vms
    );

  hostTable =
    {
      vms,
      includeUser ? true,
    }:
    builtins.concatStringsSep "\n" (
      map (
        vm:
        let
          baseFields = [ vm.name vm.ip ] ++ (if includeUser then [ (vmUser vm) ] else [ ]);
          base = builtins.concatStringsSep " " baseFields;
        in
        if vm.short != null && vm.short != vm.name then
          base + "\n" + (builtins.concatStringsSep " " ([ vm.short vm.ip ] ++ (if includeUser then [ (vmUser vm) ] else [ ])))
        else
          base
      ) vms
    );
in
{
  inherit
    vmUser
    vmList
    vmCaseBlock
    hostTable
    ;
}
