use super::*;

#[test]
fn cents_render_as_dollars_with_two_places() {
    assert_eq!(dollars(10800), "$108.00");
    assert_eq!(dollars(14805), "$148.05");
    assert_eq!(dollars(5), "$0.05");
}

#[test]
fn the_receipt_names_the_event_the_first_name_and_the_amount() {
    let body = receipt_body(Some("Ada"), "Yogadelics", Some(10800));
    assert!(body.starts_with("Hi Ada,"));
    assert!(body.contains("You're registered for Yogadelics."));
    assert!(body.contains("$108.00"));
    assert_eq!(receipt_subject("Yogadelics"), "You're registered for Yogadelics");
}

#[test]
fn a_receipt_without_a_name_or_amount_still_reads_cleanly() {
    let body = receipt_body(None, "Yogadelics", None);
    assert!(body.starts_with("Hi,"));
    assert!(!body.contains("payment of"));
}
