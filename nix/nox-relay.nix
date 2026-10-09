{
  lib,
  rustPlatform,
  vchan-libs,
}:
rustPlatform.buildRustPackage {
  pname = "nox-relay";
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
    "nox-relay"
  ];
  buildInputs = [ vchan-libs ];

  meta = {
    description = "Relays Unix sockets between Xen domains over one vchan";
    mainProgram = "nox-relay";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
