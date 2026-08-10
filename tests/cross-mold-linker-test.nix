# Copyright 2026 Anthropic, PBC
# SPDX-License-Identifier: Apache-2.0

# Regression test for cross-compiled mold links losing their RUNPATH.
#
# `-fuse-ld=mold` makes gcc search for an *unprefixed* `ld.mold`, but when
# cross compiling nixpkgs' mold wrapper installs `<triple>-ld.mold` only. gcc
# then falls through to the unwrapped mold, the ld-wrapper that adds store
# `-rpath` entries never runs, and the binary is left with an empty RUNPATH —
# it links and installs clean, then dies at exec with `cannot open shared
# object file` for any library outside glibc.
#
# Checked at instantiation, plus realising the shim, rather than by
# cross-building the sample project: a real cross Rust build needs a cross
# rustc, which is a full bootstrap and is in no binary cache.
{
  pkgs,
  plugin,
  pluginSrc,
  sampleProject,
  nix,
}:

let
  # Has to be a genuine cross from whatever this runner is: on aarch64,
  # `aarch64-multiplatform` is not a cross at all and the shim would rightly
  # be absent.
  crossName = if pkgs.stdenv.hostPlatform.isAarch64 then "gnu64" else "aarch64-multiplatform";
in
pkgs.runCommand "cargo-nix-plugin-cross-mold-linker-test"
  {
    nativeBuildInputs = [ nix ];
    requiredSystemFeatures = [ "recursive-nix" ];
  }
  ''
    export HOME=$(mktemp -d)

    crossExpr='
      let
        pkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
      in import ${pluginSrc}/lib {
        pkgs = pkgs.pkgsCross.${crossName};
        src = ${sampleProject};
      }
    '

    nativeExpr='
      let
        pkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
      in import ${pluginSrc}/lib {
        inherit pkgs;
        src = ${sampleProject};
      }
    '

    cross_drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($crossExpr).workspaceMembers.nodeps-bin.build")

    # mold must still be selected for cross — the point is to keep it, not to
    # sidestep the bug by dropping it.
    grep -q 'link-arg=-fuse-ld=mold' "$cross_drv" || {
      echo "FAIL: cross build no longer passes -fuse-ld=mold"
      exit 1
    }

    # ...and gcc must be pointed at a directory holding an unprefixed
    # `ld.mold` via -B, which it searches ahead of PATH.
    shim_drv=$(grep -o '/nix/store/[a-z0-9]*-mold-unprefixed-ld\.drv' "$cross_drv" | head -1)
    [ -n "$shim_drv" ] || {
      echo "FAIL: cross build has no mold linker dir among its inputs"
      exit 1
    }

    shim=$(nix-store --realize "$shim_drv")
    grep -q "link-arg=-B$shim/bin/" "$cross_drv" || {
      echo "FAIL: mold linker dir is not passed to gcc as -B"
      exit 1
    }
    echo "PASS: cross build keeps mold and gets an unprefixed ld.mold on -B"

    [ -x "$shim/bin/ld.mold" ] || {
      echo "FAIL: $shim/bin/ld.mold is missing or not executable"
      exit 1
    }

    # It must resolve to the *wrapper* — a shell script — and not the
    # unwrapped ELF binary. That distinction is the entire bug: both are
    # named ld.mold and only one adds the store -rpath entries.
    if [ "$(head -c 2 "$shim/bin/ld.mold")" != '#!' ]; then
      echo "FAIL: ld.mold resolves to $(readlink -f "$shim/bin/ld.mold"), which is not the wrapper script"
      exit 1
    fi
    echo "PASS: shim resolves to the wrapped linker"

    # And it must run *here*, on the build machine. Interpolating a spliced
    # package yields the host-platform mold, which cannot exec on the builder;
    # that mistake is invisible until a link actually runs.
    "$shim/bin/ld.mold" --version | grep -q '^mold' || {
      echo "FAIL: wrapped ld.mold does not run on the build platform"
      exit 1
    }
    echo "PASS: wrapped ld.mold runs on the build platform"

    # Native links already find an unprefixed ld.mold in mold's own bin, so
    # they must keep mold and stay free of the shim — otherwise this fix
    # changes every native crate's hash for nothing.
    native_drv=$(nix-instantiate \
      --option plugin-files "${plugin}/lib/nix/plugins" \
      --expr "($nativeExpr).workspaceMembers.nodeps-bin.build")

    grep -q 'link-arg=-fuse-ld=mold' "$native_drv" || {
      echo "FAIL: native build no longer passes -fuse-ld=mold"
      exit 1
    }
    if grep -q 'mold-unprefixed-ld' "$native_drv"; then
      echo "FAIL: native build gained the cross-only mold shim"
      exit 1
    fi
    echo "PASS: native build keeps mold without the shim"

    echo "$shim" > $out
  ''
