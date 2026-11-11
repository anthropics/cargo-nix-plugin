// Valid until codegen, where the assembler rejects it: the library and its
// `--test` unit build only if they stop at metadata.
std::arch::global_asm!("check_lib_not_an_instruction");

// The lib's `--test` unit lacks this item, so a bin or integration test
// checked against that unit's metadata instead of the lib's fails to resolve it.
#[cfg(not(test))]
pub fn outside_test() -> u32 {
    1
}

#[warn(clippy::useless_format)]
pub fn formatted(message: &str) -> String {
    format!("{}", message)
}

#[cfg(test)]
mod tests {
    #[test]
    fn formats() {
        assert_eq!(super::formatted("x"), "x");
    }
}
