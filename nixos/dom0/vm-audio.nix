# Sound for the VMs (2026-10-30): every wprs VM runs its own pipewire, a
# pulse-tunnel sink sends a buffered stream over the relay (service `pulse`)
# to dom0; VMs with the registry field `microphone` also get a tunnel source
# (service `pulse-mic`). dom0 answers with two pulse servers of their own
# instead of its pipewire-pulse (user services, clients of dom0's pipewire):
# - nox-pulse-vm: playback only, for every VM
# - nox-pulse-mic: recording only, runs only while `nox mic on` (off after
#   every boot); stopping it ends running recordings
# Each server blocks the other direction for every client: pulse.rules
# match client properties, which the client may set itself, so the rule
# matches a key the server sets on accept (pulse.server.type) with a regex
# for any value; quirks stay set whatever the client sends later
# (protocol-pulse, pipewire 1.6). No module loading, no D-Bus name.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (config.services.pipewire) package;

  conf =
    name: quirk:
    pkgs.writeText "nox-pulse-${name}.conf" ''
      context.properties = { }
      context.spa-libs = {
          audio.convert.* = audioconvert/libspa-audioconvert
          support.*       = support/libspa-support
      }
      context.modules = [
          { name = libpipewire-module-rt
              args = { nice.level = -11 rtportal.enabled = false }
              flags = [ ifexists nofail ]
          }
          { name = libpipewire-module-protocol-native }
          { name = libpipewire-module-client-node }
          { name = libpipewire-module-adapter }
          { name = libpipewire-module-metadata }
          { name = libpipewire-module-protocol-pulse args = { } }
      ]
      pulse.properties = {
          server.address = [ "unix:/run/user/1000/nox-pulse-${name}/native" ]
          server.dbus-name = ""
          pulse.allow-module-loading = false
      }
      pulse.rules = [
          {   matches = [ { pulse.server.type = "~.*" } ]
              actions = { quirks = [ ${quirk} ] }
          }
      ]
    '';

  service = name: description: quirk: {
    inherit description;
    after = [ "pipewire.service" ];
    wants = [ "pipewire.service" ];
    serviceConfig = {
      ExecStart = "${package}/bin/pipewire -c ${conf name quirk}";
      # the socket's directory, gone when the server stops
      RuntimeDirectory = "nox-pulse-${name}";
      Restart = "on-failure";
    };
  };
in
{
  config = lib.mkIf config.services.pipewire.enable {
    systemd.user.services = {
      nox-pulse-vm = service "vm" "pulse server for the VMs (playback only)" "block-record-stream" // {
        wantedBy = [ "default.target" ];
      };
      nox-pulse-mic =
        service "mic" "pulse server for the VMs' microphone (recording only, nox mic)"
          "block-playback-stream";
    };
  };
}
