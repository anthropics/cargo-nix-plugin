#[cfg(not(nodeps_build_ok))]
compile_error!("build.rs cargo:rustc-cfg did not reach the lib compile");

pub const BUILD_PKG: &str = env!("NODEPS_BUILD_PKG");

/// Returns the crate's greeting.
///
/// This doctest links the crate's own rlib and only compiles once the
/// build-script `nodeps_build_ok` cfg has reached the doc compile, so it
/// exercises the `doctest` derivation's extern / cfg wiring end to end.
///
/// ```
/// assert_eq!(nodeps_lib::greet(), "Hello from cargo-nix-plugin!");
/// ```
pub fn greet() -> &'static str {
    "Hello from cargo-nix-plugin!"
}

#[cfg(test)]
mod tests {
    #[test]
    fn unit() {
        assert_eq!(super::greet(), "Hello from cargo-nix-plugin!");
    }
}
