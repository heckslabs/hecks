use super::*;

#[test]
fn cents_render_as_dollars_with_two_places() {
    assert_eq!(dollars(10800), "$108.00");
    assert_eq!(dollars(14805), "$148.05");
    assert_eq!(dollars(5), "$0.05");
}

#[test]
fn the_built_in_receipt_names_the_event_the_first_name_and_the_amount() {
    let body = built_in_body(Some("Ada"), "Yogadelics", Some(10800));
    assert!(body.starts_with("Hi Ada,"));
    assert!(body.contains("You're registered for Yogadelics."));
    assert!(body.contains("$108.00"));
    assert_eq!(receipt_subject("Yogadelics"), "You're registered for Yogadelics");
}

#[test]
fn a_built_in_receipt_without_a_name_or_amount_still_reads_cleanly() {
    let body = built_in_body(None, "Yogadelics", None);
    assert!(body.starts_with("Hi,"));
    assert!(!body.contains("payment of"));
}

#[test]
fn the_sites_finished_email_is_read() {
    let answer = serde_json::json!({"subject": "You're registered for Yogadelics", "body": "Hi Ada,\n\nWhere: Somewhere\n"});
    assert_eq!(
        site_email_from_json(&answer),
        Some(SiteEmail { subject: "You're registered for Yogadelics".into(), body: "Hi Ada,\n\nWhere: Somewhere\n".into() })
    );
}

#[test]
fn an_incomplete_answer_from_the_site_falls_back_to_the_built_in_wording() {
    assert_eq!(site_email_from_json(&serde_json::json!({"error": "no such session"})), None);
    assert_eq!(site_email_from_json(&serde_json::json!({"subject": "Hi", "body": "  "})), None);
}
