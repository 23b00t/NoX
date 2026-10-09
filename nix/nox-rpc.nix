{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "nox-rpc";
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
    "nox-rpc"
  ];
  cargoTestFlags = [
    "-p"
    "nox-rpc"
  ];

  meta = {
    description = "qrexec-like RPC between Xen domains, mediated by dom0 (over nox-relay)";
    mainProgram = "nox-rpc";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
