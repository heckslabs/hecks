//! ToolShed borrow/return cascade — the belongs_to fix (VALIDATOR-cross-
//! aggregate-policy-ref-naming). Returning a loan must check in the tool that
//! was borrowed, NOT an arbitrary one. Under the old `reference_to Tool` the
//! ToolReturned event carried no tool id, so CheckInOnReturn fell to the
//! singleton fallback (repo.all().first()) and flipped the WRONG tool. With
//! `belongs_to Tool` the runtime injects the tool id from Loan state, so the
//! borrowed tool — and only it — comes back on the shelf.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const TOOLSHED: &str = include_str!("../../examples/workshop_demo/toolshed.bluebook");

fn tool_id_named(rt: &Runtime, name: &str) -> String {
    rt.all("Tool")
        .into_iter()
        .find(|r| r.get("name").to_string() == name)
        .unwrap_or_else(|| panic!("tool '{}' exists", name))
        .id
        .clone()
}
fn availability(rt: &Runtime, id: &str) -> String {
    rt.all("Tool")
        .into_iter()
        .find(|r| r.id == id)
        .expect("tool exists")
        .get("availability")
        .to_string()
}

#[test]
fn returning_a_loan_checks_in_the_borrowed_tool_not_an_arbitrary_one() {
    let mut rt = Runtime::boot(parser::parse(TOOLSHED));
    rt.dispatch(
        "AddTool",
        attrs(&[
            ("name", s("Drill")),
            ("category", s("power")),
            ("daily_fee", s("500")),
            ("deposit", s("2000")),
        ]),
    )
    .expect("add drill");
    rt.dispatch(
        "AddTool",
        attrs(&[
            ("name", s("Ladder")),
            ("category", s("access")),
            ("daily_fee", s("300")),
            ("deposit", s("1500")),
        ]),
    )
    .expect("add ladder");
    rt.dispatch(
        "EnrollMember",
        attrs(&[("name", s("Ada")), ("email", s("ada@example.org"))]),
    )
    .expect("enroll member");

    let drill = tool_id_named(&rt, "Drill");
    let ladder = tool_id_named(&rt, "Ladder");
    let member = rt.all("Member")[0].id.clone();

    // Borrow the LADDER — deliberately not the first tool the singleton
    // fallback (repo.all().first() = Drill) would grab.
    rt.dispatch(
        "BorrowTool",
        attrs(&[
            ("tool", s(&ladder)),
            ("member", s(&member)),
            ("due_on", s("2026-08-01")),
        ]),
    )
    .expect("borrow ladder");

    assert_eq!(availability(&rt, &ladder), "out", "CheckOutOnBorrow flipped the ladder");
    assert_eq!(availability(&rt, &drill), "available", "the drill was untouched");

    // Return the loan.
    let loan = rt.all("Loan")[0].id.clone();
    rt.dispatch("ReturnTool", attrs(&[("loan", s(&loan))]))
        .expect("return loan");

    // The RIGHT tool comes back : belongs_to carries the tool id on
    // ToolReturned. Under the reference_to bug this asserted line fails — the
    // fallback would flip the drill and leave the ladder stuck 'out'.
    assert_eq!(
        availability(&rt, &ladder),
        "available",
        "the returned ladder is back on the shelf"
    );
    assert_eq!(
        availability(&rt, &drill),
        "available",
        "the drill stayed available throughout"
    );
}
