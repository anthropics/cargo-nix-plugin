// Copyright 2026 Anthropic, PBC
// SPDX-License-Identifier: Apache-2.0

//! Documentation tests (`rustdoc --test`, i.e. `cargo test --doc`).
//!
//! Runs after the `build` phase of the `buildTests` variant, so the crate's
//! own rlib is already compiled under `target/lib` and every dependency
//! (dev-dependencies included, since `buildTests = true`) is symlinked into
//! `target/deps`. We reuse the exact externs / features / edition /
//! build-script cfgs that compiled the lib — the same `RustcFlags` the lib
//! build used — so doctests can't pass vacuously against a stale or divergent
//! dependency set. A crate without a lib target is a no-op, matching
//! `cargo test --doc`.

use std::process::Command;

use super::build::{resolve_lib_path, setup_build};
use super::config::BuildConfig;
use super::configure::detect_cargo_toml_info;
use super::rustc::{RustcFlags, find_by_metadata};
use super::util::{echo_colored, run_cmd};

pub fn run(config: &mut BuildConfig) -> Result<(), Box<dyn std::error::Error>> {
    detect_cargo_toml_info(config);

    let Some(lib_src) = resolve_lib_path(config) else {
        echo_colored(&format!(
            "No lib target for {}; no doctests to run",
            config.crate_name
        ));
        return Ok(());
    };

    let flags = setup_build(config)?;
    let crate_name = config.lib_name_normalized();

    // rustdoc doctests link the crate under test, so point `--extern` at the
    // rlib the `build` phase produced under target/lib.
    let self_lib = find_by_metadata("target/lib", &config.metadata).ok_or_else(|| {
        format!(
            "doctest: compiled lib for {crate_name} not found under target/lib \
             (metadata {}); `doctest` must run after `build`",
            config.metadata
        )
    })?;

    echo_colored(&format!("Doc-testing {lib_src} ({})", config.lib_name));

    let args = doctest_args(&flags, &crate_name, &config.crate_type, &lib_src, &self_lib);
    let mut cmd = Command::new("rustdoc");
    cmd.env("CARGO_CRATE_NAME", &crate_name);
    cmd.env("CARGO_PRIMARY_PACKAGE", "1");
    cmd.args(&args);
    run_cmd(&mut cmd, config.verbose)?;

    Ok(())
}

/// Assemble the `rustdoc --test` argument list (program name excluded). Pure
/// so the flag wiring can be unit-tested without a full build tree.
fn doctest_args(
    flags: &RustcFlags,
    crate_name: &str,
    crate_types: &[String],
    lib_src: &str,
    self_lib: &str,
) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "--test".into(),
        "--crate-name".into(),
        crate_name.into(),
        lib_src.into(),
    ];

    // Only Rust-linkable crate types make sense for a doc target; a bin/
    // cdylib/staticlib-only entry would make rustdoc reject the input.
    for ct in crate_types {
        if matches!(ct.as_str(), "lib" | "rlib" | "proc-macro" | "dylib") {
            args.push("--crate-type".into());
            args.push(ct.clone());
        }
    }

    args.push("-L".into());
    args.push("dependency=target/deps".into());
    // The crate itself, so `use <crate>;` in the examples resolves.
    args.push("--extern".into());
    args.push(format!("{crate_name}={self_lib}"));

    // Dependency `--extern`s, features, edition, codegen/target/linker opts.
    args.extend_from_slice(&flags.base);
    // Build-script `--cfg` / `--check-cfg` / link flags.
    args.extend_from_slice(&flags.link);
    // `-L <OUT_DIR>` when a build script emitted one.
    args.extend_from_slice(&flags.out_dir);

    args.push("--cap-lints".into());
    args.push(flags.cap_lints.clone());
    args.push("--color".into());
    args.push(flags.colors.clone());
    args
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn flags() -> RustcFlags {
        RustcFlags {
            base: vec![
                "--extern".into(),
                "serde=target/deps/libserde-abc.rlib".into(),
                "--cfg".into(),
                "feature=\"std\"".into(),
                "--edition".into(),
                "2021".into(),
            ],
            meta: vec!["-C".into(), "metadata=deadbeef".into()],
            link: vec!["--cfg".into(), "have_atomics".into()],
            bso_lib: vec![],
            bso_bins: vec![],
            bso_bin: BTreeMap::new(),
            bso_tests: vec![],
            bso_cdylib: vec![],
            out_dir: vec!["-L".into(), "/build/out".into()],
            cap_lints: "allow".into(),
            colors: "always".into(),
        }
    }

    fn has_pair(args: &[String], a: &str, b: &str) -> bool {
        args.windows(2).any(|w| w[0] == a && w[1] == b)
    }

    #[test]
    fn doctest_args_wire_self_extern_deps_and_flags() {
        let f = flags();
        let args = doctest_args(
            &f,
            "mycrate",
            &["lib".into()],
            "src/lib.rs",
            "target/lib/libmycrate-deadbeef.rlib",
        );

        assert!(args.contains(&"--test".into()));
        assert!(has_pair(&args, "--crate-name", "mycrate"));
        assert!(args.contains(&"src/lib.rs".into()));
        assert!(has_pair(&args, "--crate-type", "lib"));
        // Its own rlib and the deps search dir.
        assert!(has_pair(
            &args,
            "--extern",
            "mycrate=target/lib/libmycrate-deadbeef.rlib"
        ));
        assert!(has_pair(&args, "-L", "dependency=target/deps"));
        // Dependency externs, features, edition, and build-script cfgs forwarded.
        assert!(has_pair(
            &args,
            "--extern",
            "serde=target/deps/libserde-abc.rlib"
        ));
        assert!(has_pair(&args, "--cfg", "feature=\"std\""));
        assert!(has_pair(&args, "--edition", "2021"));
        assert!(has_pair(&args, "--cfg", "have_atomics"));
        assert!(has_pair(&args, "-L", "/build/out"));
        assert!(has_pair(&args, "--cap-lints", "allow"));
        assert!(has_pair(&args, "--color", "always"));
        // `-C metadata` / `extra-filename` are lib-build only; a doc target
        // must not carry them.
        assert!(!args.iter().any(|a| a.starts_with("metadata=")));
    }

    #[test]
    fn doctest_args_skip_non_linkable_crate_types() {
        let f = flags();
        let args = doctest_args(
            &f,
            "tool",
            &["bin".into(), "cdylib".into()],
            "src/lib.rs",
            "target/lib/libtool-deadbeef.rlib",
        );
        assert!(!args.iter().any(|a| a == "bin" || a == "cdylib"));
    }
}
