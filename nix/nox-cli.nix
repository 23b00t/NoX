{
  lib,
  rustPlatform,
  installShellFiles,
}:
rustPlatform.buildRustPackage {
  pname = "nox-cli";
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
    "nox-cli"
  ];
  cargoTestFlags = [
    "-p"
    "nox-cli"
  ];
  nativeBuildInputs = [ installShellFiles ];
  postInstall = ''
    installShellCompletion --bash --name nox crates/nox-cli/completions/nox.bash
  '';

  meta = {
    description = "One command for the NoX tools in dom0 (thin wrapper over the scripts)";
    mainProgram = "nox";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
