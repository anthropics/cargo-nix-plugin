# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

# End-to-end build test: resolve, compile, and run a small Rust workspace
# using the nix plugin + buildRustCrate, all inside a single derivation.
# The workspace has two members (sample-lib, sample-bin) to exercise
# inter-workspace-member dependencies.
{
  pkgs,
  plugin,
  pluginSrc,
  sampleProject,
  nix,
}:

pkgs.runCommand "cargo-nix-plugin-sample-build-test"
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
        metadata = builtins.readFile "${sampleProject}/metadata.json";
        cargoLock = builtins.readFile "${sampleProject}/Cargo.lock";
        src = ${sampleProject};
      }
    '

    # --- Build test: compile and run the binary workspace member ---
    drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($cargoNixExpr).workspaceMembers.sample-bin.build")

    # --realize may print multiple outputs (out + lib); take the first.
    built=$(nix-store --realize "$drv" | grep -v -- '-lib$' | head -1)
    out_json=$("$built"/bin/sample-bin)
    echo "Output: $out_json"

    msg=$(echo "$out_json" | jq -r .message)
    [[ "$msg" == "Hello from cargo-nix-plugin!" ]] || {
      echo "FAIL: unexpected message: $msg"
      exit 1
    }

    # env!("CARGO_MANIFEST_DIR") is expanded at compile time and cannot be
    # rewritten by --remap-path-prefix, so it must not be derived from the
    # build directory, which Nix is free to choose per build.
    manifest_dir=$(echo "$out_json" | jq -r .manifest_dir)
    [[ "$manifest_dir" == /nix/store/*/.cargo-manifest ]] || {
      echo "FAIL: CARGO_MANIFEST_DIR is not stable: $manifest_dir"
      exit 1
    }

    echo "PASS: workspace built and ran successfully"

    # --- Lib-only dep split: sample-lib has a sidecar bin (sample-tool).
    # When built as the root crate, the bin is present; when pulled in as
    # a dependency of sample-bin (cratesLibOnly), the bin is suppressed.
    lib_root_drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($cargoNixExpr).workspaceMembers.sample-lib.build")
    lib_dep_drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "let c = ($cargoNixExpr); in builtins.getAttr c.resolved.workspaceMembers.sample-lib c.builtCrates.cratesLibOnly")

    [[ "$lib_root_drv" != "$lib_dep_drv" ]] || {
      echo "FAIL: lib-only dep drv should differ from with-bins root drv"
      exit 1
    }

    # --realize prints all outputs in hash order; pick the one without -lib suffix.
    lib_root=$(nix-store --realize "$lib_root_drv" | grep -v -- '-lib$')
    lib_dep=$(nix-store --realize "$lib_dep_drv" | grep -v -- '-lib$')

    [[ -x "$lib_root/bin/sample-tool" ]] || {
      echo "FAIL: workspaceMembers.sample-lib.build should include bin/sample-tool"
      exit 1
    }
    [[ ! -e "$lib_dep/bin/sample-tool" ]] || {
      echo "FAIL: lib-only dep of sample-lib should NOT include bin/sample-tool"
      exit 1
    }
    echo "PASS: lib-only dep split suppresses sidecar bins"

    # Built as the root crate, sample-lib's manifest dir must resolve to its
    # own out path. That path is fixed at eval time, so it is the same
    # whichever directory Nix picks to build in.
    tool_manifest_dir=$("$lib_root"/bin/sample-tool | jq -r .manifest_dir)
    [[ "$tool_manifest_dir" == "$lib_root/.cargo-manifest" ]] || {
      echo "FAIL: CARGO_MANIFEST_DIR is not output-derived: $tool_manifest_dir"
      exit 1
    }

    # ...and no path under the build directory may survive in the artifact.
    # Nix builds in /build when sandboxed and under /tmp/nix-build otherwise.
    # Match only paths naming the workspace: rustc's own /build/rustc-*-src
    # source paths come from the compiler in nixpkgs and are expected.
    if grep -qaE '(/build|/tmp/nix-build)[^ ]*sample-project' "$lib_root/bin/sample-tool"; then
      echo "FAIL: sample-tool embeds a build-directory path:"
      grep -oaE '(/build|/tmp/nix-build)[^ ]*sample-project[^ ]*' "$lib_root/bin/sample-tool" |
        sort -u | head
      exit 1
    fi
    echo "PASS: CARGO_MANIFEST_DIR is independent of the build directory"

    # --- Clippy test: lint all workspace members with clippy-driver ---
    clippy_drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($cargoNixExpr).clippy.allWorkspaceMembers")

    nix-store --realize "$clippy_drv" > /dev/null
    echo "PASS: clippy check succeeded"

    clippy_report_drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($cargoNixExpr).clippy.report")

    clippy_report=$(nix-store --realize "$clippy_report_drv")
    jq -e -s 'any(.[]; .level == "warning")' "$clippy_report/sample-lib.jsonl" > /dev/null
    echo "PASS: cached clippy report retained JSON diagnostics"

    # reportCheck must fail because sample-lib carries an intentional
    # clippy::useless_format warning.
    clippy_check_drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($cargoNixExpr).clippy.reportCheck")

    if nix-store --realize "$clippy_check_drv" 2>/dev/null; then
      echo "FAIL: clippy.reportCheck succeeded despite warnings"
      exit 1
    fi
    echo "PASS: clippy.reportCheck fails on warnings"

    echo "$out_json" > $out
  ''
