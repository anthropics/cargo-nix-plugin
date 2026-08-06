# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

# End-to-end test for workspaceMembers.<name>.doctest. nodeps-lib carries a
# `///` example on `greet()`; the derivation must compile and run it, linking
# the crate's own rlib and honouring the build-script `nodeps_build_ok` cfg. A
# lib-less member must still build (a no-op, like `cargo test --doc`).
{
  pkgs,
  plugin,
  pluginSrc,
  sampleProject,
  nix,
}:

pkgs.runCommand "cargo-nix-plugin-doctest-run-test"
  {
    nativeBuildInputs = [ nix ];
    requiredSystemFeatures = [ "recursive-nix" ];
  }
  ''
    export HOME=$(mktemp -d)

    cargoNixExpr='
      let
        pkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
      in import ${pluginSrc}/lib {
        inherit pkgs;
        src = ${sampleProject};
      }
    '

    # The lib member's doctest must build and run (a passing `greet()` example).
    # A failing doctest would make `rustdoc --test` exit non-zero and fail this
    # realize, so a green build means the example actually ran.
    drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($cargoNixExpr).workspaceMembers.nodeps-lib.doctest")
    nix-store --realize "$drv" > /dev/null
    echo "PASS: doctest compiled and ran the lib's documentation examples"

    # A bin-only member has no lib target, so its doctest is a no-op that
    # still builds successfully (matching `cargo test --doc`).
    bindrv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($cargoNixExpr).workspaceMembers.nodeps-bin.doctest")
    nix-store --realize "$bindrv" > /dev/null
    echo "PASS: doctest is a no-op for a lib-less member"

    touch $out
  ''
