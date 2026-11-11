#[test]
fn expands() {
    assert_eq!(check_macro::answer!(), 42);
}
