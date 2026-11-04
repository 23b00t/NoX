{
  lib,
  rustPlatform,
  pkg-config,
  pipewire,
  gst_all_1,
}:
rustPlatform.buildRustPackage {
  pname = "nox-screencast";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../crates
    ];
  };
  cargoLock.lockFile = ../Cargo.lock;
  cargoBuildFlags = [
    "-p"
    "nox-screencast"
  ];
  cargoTestFlags = [
    "-p"
    "nox-screencast"
  ];

  # nox-screencast-receive: PipeWire stream (bindgen) + GStreamer decoding
  nativeBuildInputs = [
    pkg-config
    rustPlatform.bindgenHook
  ];
  buildInputs = [
    pipewire
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
  ];

  meta = {
    description = "Screen sharing from dom0 into VMs: cast helper (dom0), portal backend, receiver and session-bus bridge (VMs)";
    mainProgram = "nox-screencast-portal";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
