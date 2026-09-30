use super::*;

#[test]
fn cents_render_as_dollars_with_two_places() {
    assert_eq!(dollars(10800), "$108.00");
    assert_eq!(dollars(14805), "$148.05");
    assert_eq!(dollars(5), "$0.05");
}

#[test]
fn the_receipt_names_the_event_the_first_name_and_the_amount() {
    let body = receipt_body(Some("Ada"), "Yogadelics", Some(10800), &SessionDetails::default());
    assert!(body.starts_with("Hi Ada,"));
    assert!(body.contains("You're registered for Yogadelics."));
    assert!(body.contains("$108.00"));
    assert_eq!(receipt_subject("Yogadelics"), "You're registered for Yogadelics");
}

#[test]
fn a_receipt_without_a_name_or_amount_still_reads_cleanly() {
    let body = receipt_body(None, "Yogadelics", None, &SessionDetails::default());
    assert!(body.starts_with("Hi,"));
    assert!(!body.contains("payment of"));
}

#[test]
fn the_receipt_lists_when_and_where_when_the_site_knows_them() {
    let session = SessionDetails { when: Some("Friday, October 16 · 6:30–8:30 pm".into()), place: Some("Phoenix, Arizona".into()) };
    let body = receipt_body(Some("Ada"), "Yogadelics", Some(10800), &session);
    assert!(body.contains("When: Friday, October 16 · 6:30–8:30 pm\nWhere: Phoenix, Arizona\n"));
}

#[test]
fn a_session_without_a_venue_lists_only_the_time() {
    let session = SessionDetails { when: Some("Friday, October 16".into()), place: None };
    let body = receipt_body(None, "Yogadelics", None, &session);
    assert!(body.contains("When: Friday, October 16"));
    assert!(!body.contains("Where:"));
}

#[test]
fn the_sites_answer_is_read_and_blank_fields_are_dropped() {
    let body = serde_json::json!({"name": "Yogadelics", "when": " Friday ", "where": "  "});
    assert_eq!(session_from_json(&body), SessionDetails { when: Some("Friday".into()), place: None });
    assert_eq!(session_from_json(&serde_json::json!({"error": "no such session"})), SessionDetails::default());
}
