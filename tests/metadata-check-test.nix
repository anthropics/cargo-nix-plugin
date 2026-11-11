# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

# End-to-end test for clippy `.check` / `.checkTests`, which stop the root
# library and terminal targets at metadata emission. check-lib's bin and
# integration test must resolve against the library's own metadata, the
# library's lints must still reach the report, a proc-macro root must stay
# loadable by its integration test, and an rlib+cdylib root must check.
{
  pkgs,
  plugin,
  pluginSrc,
  checkProject,
  nix,
}:

pkgs.runCommand "cargo-nix-plugin-metadata-check-test"
  {
    nativeBuildInputs = [
      nix
      pkgs.jq
    ];
    requiredSystemFeatures = [ "recursive-nix" ];
  }
  ''
    export HOME=$(mktemp -d)

    cargoNixExpr='
      let
        pkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
      in import ${pluginSrc}/lib {
        inherit pkgs;
        src = ${checkProject};
      }
    '

    for member in check-lib check-macro check-cdylib; do
      for attr in check checkTests; do
        drv=$(nix-instantiate \
          --option plugin-files "${plugin}/lib/nix/plugins" \
          --expr "($cargoNixExpr).clippy.workspaceMembers.$member.$attr")
        out=$(nix-store --realize "$drv")
        if [[ $member == check-lib ]]; then
          jq -e -s 'any(.[]; .code.code == "clippy::useless_format")' \
            "$out/share/cargo-nix/clippy-diagnostics.jsonl" > /dev/null || {
            echo "FAIL: $member.$attr lost the root library's lint"
            exit 1
          }
        fi
        echo "PASS: $member.$attr"
      done
    done

    touch $out
  ''
