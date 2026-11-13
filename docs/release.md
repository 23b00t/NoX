# Releasing NoX

Checklist for the maintainer. A release is a signed git tag `vX.Y.Z` plus a
GitHub Release with the installer ISO, `SHA256SUMS` and `SHA256SUMS.sig`,
both signed with the offline key `nox-release` (SSH, ed25519). Building the
ISO yourself from the signed tag stays the recommended way; the ISO on
GitHub is a convenience. How users verify: README, "Verify a release".

Paths below: `$KEY` is the private key on the stick (e.g.
`/run/media/$USER/stick/nox-release`), `$KEY.pub` its public part. Run
everything in a clean checkout of NoX on the commit to release. Never run
`nix flake check` on the hp (it builds and evaluates every machine); use
the named checks below.

## Once: create the key

```sh
ssh-keygen -t ed25519 -C nox-release -f "$KEY"
ssh-keygen -lf "$KEY.pub"
```

Put the public key into `release/allowed-signers` (uncomment the line,
paste `cat "$KEY.pub"` after `namespaces="git,nox-release"`) and commit it.
Publish the fingerprint (`SHA256:…` from `ssh-keygen -lf`) on at least two
channels outside the repo (GitHub profile, a website): a fingerprint that
only stands in the repo proves nothing. The private key never leaves the
stick.

## Each release

1. Refresh the pins. The template's nixpkgs follows NoX's, so NoX first:

   ```sh
   nix flake update
   nix flake update --flake ./template
   ```

   (`template/flake.lock` pins NoX from GitHub, so it lags one commit; nox-install
   re-pins NoX and its inputs to the ISO's revision anyway.)
2. Raise `whonixMinVersion` in `nix/nox-install.nix` to the current Whonix
   stable release (the version its KVM page downloads).
3. Regenerate the option reference ([options-doc.nix](../nix/options-doc.nix)):

   ```sh
   install -m 644 "$(nix build .#options-doc --no-link --print-out-paths)" docs/options.md
   ```

4. Eval checks, per machine (`registry-<host>`, `noxInstall-<host>`, see
   `nixos/lib/systems.nix`; `nix flake show` lists the names):

   ```sh
   nix build --no-link ".#checks.x86_64-linux.registry-<host>" ".#checks.x86_64-linux.noxInstall-<host>"
   ```

   Commit the result (signed, as usual) and push; the release is this commit.
5. Build the ISO from the tagged state and look at its size:

   ```sh
   nix build "github:23b00t/NoX/$(git rev-parse HEAD)#installer-iso" -o iso
   ls -lh iso/iso/*.iso
   ```

   GitHub allows 2 GiB per asset. If it is larger: compress it
   (`xz -9`, then the checksum is of the `.xz`), or publish only
   `SHA256SUMS` and the build instructions.
6. Optional: reproducibility check. Build the same ISO from the same
   tagged revision on a second machine with Nix (e.g. hp and nox-vm) and
   compare the hashes:

   ```sh
   nix build "github:23b00t/NoX/<rev>#installer-iso" -o iso2
   sha256sum iso/iso/*.iso iso2/iso/*.iso
   ```

   Same hash: write "reproducible: built on two machines, same SHA-256"
   into the release notes. Different hash: release anyway, say so in the
   release notes, and optionally look at the difference with
   `nix run nixpkgs#diffoscope -- a.iso b.iso`. NixOS tracks the same for
   its minimal ISO at <https://reproducible.nixos.org/>.
7. Checksums and their signature (namespace `nox-release`):

   ```sh
   cp iso/iso/*.iso . && sha256sum nox-*.iso > SHA256SUMS
   ssh-keygen -Y sign -f "$KEY" -n nox-release SHA256SUMS
   ```

   This writes `SHA256SUMS.sig`. Check it before uploading:

   ```sh
   ssh-keygen -Y verify -f release/allowed-signers -I nox-release -n nox-release -s SHA256SUMS.sig < SHA256SUMS
   ```
8. Signed annotated tag (git signs with namespace `git`), then push it:

   ```sh
   git -c gpg.format=ssh -c user.signingkey="$KEY.pub" tag -s vX.Y.Z -m 'NoX X.Y.Z'
   git -c gpg.ssh.allowedSignersFile=release/allowed-signers verify-tag vX.Y.Z
   git push origin vX.Y.Z
   ```

   `user.signingkey` as a `.pub` path makes git ask ssh-agent for the
   matching key; if it is not loaded, `ssh-add "$KEY"` first (or give the
   private key path, which `ssh-keygen -Y sign` then reads directly).
9. The release (`--verify-tag` aborts if the tag is not on GitHub; put the
   reproducibility line from step 6 into the notes):

   ```sh
   gh release create vX.Y.Z nox-*.iso SHA256SUMS SHA256SUMS.sig --verify-tag --title 'NoX X.Y.Z' --notes 'Changes: …'
   ```
