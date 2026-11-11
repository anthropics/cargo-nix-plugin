#[test]
fn uses_lib() {
    assert_eq!(check_lib::outside_test(), 1);
    let _ = env!("CARGO_BIN_EXE_check-lib");
}
