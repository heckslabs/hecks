
use crate::sqlite_repository::SqliteRepository;
use storehouse::runtime::{AggregateState, Value};
use storehouse::heki;
use storehouse::ir::{WhereClause, WhereOp};
use std::collections::HashMap;

fn clause(field: &str, op: WhereOp, value: &str) -> WhereClause {
    WhereClause { field: field.into(), op, value: value.into() }
}

fn db_path(name: &str) -> String {
    std::env::temp_dir()
        .join(format!("query_parity_{}_{}.db", std::process::id(), name))
        .to_string_lossy()
        .into_owned()
}

const EVIL: &str = "x'; DROP TABLE order; --";

fn seeded(name: &str) -> SqliteRepository {
    let path = db_path(name);
    let _ = std::fs::remove_file(&path);
    let cols = vec![
        ("status".to_string(), "VARCHAR(255)".to_string()),
        ("priority".to_string(), "INTEGER".to_string()),
    ];
    let mut repo = SqliteRepository::new("Ticket", &path, cols, HashMap::new()).expect("open db");
    let rows = [
        ("1", "pending", 1),
        ("2", "paid", 10),
        ("3", "pending", 2),
        ("4", "shipped", 9),
        ("5", EVIL, 5),
    ];
    for (id, status, priority) in rows {
        let mut s = AggregateState::new(id);
        s.set("status", Value::Str(status.into()));
        s.set("priority", Value::Int(priority));
        repo.save(s, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();
    }
    repo
}

fn sorted(mut ids: Vec<String>) -> Vec<String> {
    ids.sort();
    ids
}

fn oracle_filter(
    states: &[&AggregateState],
    wheres: &[WhereClause],
    attrs: &HashMap<String, String>,
) -> Vec<String> {
    sorted(
        states
            .iter()
            .filter(|s| wheres.iter().all(|w| storehouse::runtime::where_matches(s, w, attrs)))
            .map(|s| s.id.clone())
            .collect(),
    )
}

fn raw_ids(states: &[AggregateState]) -> Vec<String> {
    sorted(states.iter().map(|s| s.id.clone()).collect())
}

fn assert_parity(repo: &SqliteRepository, wheres: &[WhereClause], attrs: &HashMap<String, String>) {
    let all = repo.all();
    let oracle_full = oracle_filter(&all, wheres, attrs);

    let candidates = repo.query(wheres, attrs);
    let cand_refs: Vec<&AggregateState> = candidates.iter().collect();

    assert_eq!(
        oracle_filter(&cand_refs, wheres, attrs),
        oracle_full,
        "oracle(candidates) must equal oracle(store) for {wheres:?}"
    );

    let raw = raw_ids(&candidates);
    for id in &oracle_full {
        assert!(raw.contains(id), "candidate set dropped oracle match {id} for {wheres:?}");
    }
}

#[test]
fn parity_across_every_op() {
    let repo = seeded("ops");
    let attrs = HashMap::new();
    let cases: Vec<Vec<WhereClause>> = vec![
        vec![clause("status", WhereOp::Eq, "pending")],
        vec![clause("status", WhereOp::Ne, "pending")],
        vec![clause("status", WhereOp::In, "pending, shipped")],
        vec![clause("priority", WhereOp::Eq, "10")],
        vec![clause("priority", WhereOp::Gt, "5")],
        vec![clause("priority", WhereOp::Gte, "9")],
        vec![clause("priority", WhereOp::Lt, "5")],
        vec![clause("priority", WhereOp::Lte, "2")],
        vec![clause("status", WhereOp::Gt, "pending")],
        vec![clause("status", WhereOp::Gte, "pending")],
        vec![clause("status", WhereOp::Lt, "shipped")],
        vec![clause("status", WhereOp::Lte, "pending")],
        vec![clause("status", WhereOp::Eq, "pending"), clause("priority", WhereOp::Gt, "1")],
        vec![clause("status", WhereOp::Gt, "pending"), clause("priority", WhereOp::Lt, "5")],
    ];
    for wheres in &cases {
        assert_parity(&repo, wheres, &attrs);
    }
}

// A COLUMN THAT HOLDS AN OBJECT, queried by the scalar inside it. The in-memory
// oracle (`where_matches` -> `resolve_state_field`) opens a one-key map and
// matches ; the SQL pushdown compares the whole stored text and does not. If the
// two disagree the store answers less than the oracle, and `sqlite_query`'s
// fallback cannot save it — that fallback fires only when pushdown returns None,
// never when it returns an empty set.
#[test]
fn object_valued_column_matches_the_same_rows_as_the_oracle() {
    let path = db_path("object_column");
    let _ = std::fs::remove_file(&path);
    let cols = vec![("account".to_string(), "VARCHAR(255)".to_string())];
    let mut repo = SqliteRepository::new("Card", &path, cols, HashMap::new()).expect("open db");

    for (id, account) in [("c1", "acct-1"), ("c2", "acct-2")] {
        let mut s = AggregateState::new(id);
        let mut held: HashMap<String, Value> = HashMap::new();
        held.insert("value".to_string(), Value::Str(account.into()));
        s.set("account", Value::Map(held));
        repo.save(s, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();
    }

    let attrs = HashMap::new();
    for wheres in [
        vec![clause("account", WhereOp::Eq, "acct-1")],
        vec![clause("account", WhereOp::Ne, "acct-1")],
        vec![clause("account", WhereOp::In, "acct-1, acct-9")],
        vec![clause("account", WhereOp::Gt, "acct-1")],
        vec![clause("account", WhereOp::Lte, "acct-1")],
    ] {
        assert_parity(&repo, &wheres, &attrs);
    }
}

#[test]
fn pushed_eq_actually_narrows_at_sql() {
    let repo = seeded("narrow");
    let attrs = HashMap::new();
    let wheres = vec![clause("status", WhereOp::Eq, "pending")];
    let candidates = repo.query(&wheres, &attrs);
    assert_eq!(raw_ids(&candidates), vec!["1".to_string(), "3".to_string()]);
    assert!(candidates.len() < repo.all().len(), "pushdown must narrow");
}

#[test]
fn pushed_nonnumeric_range_narrows_at_sql() {
    let repo = seeded("range_narrow");
    let attrs = HashMap::new();
    let wheres = vec![clause("status", WhereOp::Gt, "pending")];
    let candidates = repo.query(&wheres, &attrs);
    assert_eq!(raw_ids(&candidates), vec!["4".to_string(), "5".to_string()]);
    assert!(candidates.len() < repo.all().len(), "range pushdown must narrow");
}

#[test]
fn numeric_range_narrows_at_sql() {
    let repo = seeded("numeric_range");
    let attrs = HashMap::new();
    let wheres = vec![clause("priority", WhereOp::Gt, "5")];
    let candidates = repo.query(&wheres, &attrs);
    assert_eq!(raw_ids(&candidates), vec!["2".to_string(), "4".to_string()], "priority > 5 : 10 and 9");
    assert!(candidates.len() < repo.all().len(), "numeric range must narrow at SQL");
}

#[test]
fn numeric_range_null_priority_matches_oracle() {
    let path = db_path("null_priority");
    let _ = std::fs::remove_file(&path);
    let cols = vec![
        ("status".to_string(), "VARCHAR(255)".to_string()),
        ("priority".to_string(), "INTEGER".to_string()),
    ];
    let mut repo = SqliteRepository::new("Ticket", &path, cols, HashMap::new()).expect("open db");
    let mut a = AggregateState::new("1");
    a.set("status", Value::Str("x".into()));
    a.set("priority", Value::Int(3));
    repo.save(a, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();
    let mut b = AggregateState::new("2");
    b.set("status", Value::Str("x".into()));
    b.set("priority", Value::Int(8));
    repo.save(b, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();
    let mut c = AggregateState::new("3"); 
    c.set("status", Value::Str("x".into()));
    repo.save(c, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();
    let attrs = HashMap::new();
    for op in [WhereOp::Gt, WhereOp::Gte, WhereOp::Lt, WhereOp::Lte] {
        assert_parity(&repo, &[clause("priority", op, "5")], &attrs);
    }
    let lt_w = vec![clause("priority", WhereOp::Lt, "5")];
    let lt = repo.query(&lt_w, &attrs);
    let lt_refs: Vec<&AggregateState> = lt.iter().collect();
    assert!(oracle_filter(&lt_refs, &lt_w, &attrs).contains(&"3".to_string()), "Lt keeps NULL row");
    let gt_w = vec![clause("priority", WhereOp::Gt, "5")];
    let gt = repo.query(&gt_w, &attrs);
    let gt_refs: Vec<&AggregateState> = gt.iter().collect();
    assert!(!oracle_filter(&gt_refs, &gt_w, &attrs).contains(&"3".to_string()), "Gt drops NULL row");
}

#[test]
fn numeric_eq_does_not_match_via_affinity() {
    let repo = seeded("affinity");
    let attrs = HashMap::new();
    let wheres = vec![clause("priority", WhereOp::Eq, "05")];
    assert!(repo.query(&wheres, &attrs).is_empty() || {
        let cands = repo.query(&wheres, &attrs);
        let refs: Vec<&AggregateState> = cands.iter().collect();
        oracle_filter(&refs, &wheres, &attrs).is_empty()
    });
}

#[test]
fn where_matches_resolves_nested_vo_bare_and_dotted() {
    let mut s = AggregateState::new("e1");
    let mut seqmap = HashMap::new();
    seqmap.insert("value".to_string(), Value::Int(7));
    s.set("sequence", Value::Map(seqmap));
    let attrs = HashMap::new();
    assert!(storehouse::runtime::where_matches(&s, &clause("sequence", WhereOp::Eq, "7"), &attrs), "bare VO unwraps to 7");
    assert!(storehouse::runtime::where_matches(&s, &clause("sequence", WhereOp::Gt, "5"), &attrs), "7 > 5 via unwrap");
    assert!(!storehouse::runtime::where_matches(&s, &clause("sequence", WhereOp::Eq, "8"), &attrs), "7 != 8");
    assert!(storehouse::runtime::where_matches(&s, &clause("sequence.value", WhereOp::Gt, "5"), &attrs), "7 > 5");
    assert!(storehouse::runtime::where_matches(&s, &clause("sequence.value", WhereOp::Eq, "7"), &attrs), "7 == 7");
    assert!(!storehouse::runtime::where_matches(&s, &clause("sequence.value", WhereOp::Lt, "7"), &attrs), "7 < 7 false");
    assert!(!storehouse::runtime::where_matches(&s, &clause("sequence.nope", WhereOp::Eq, "7"), &attrs), "missing leaf");
}

// A VALUE-OBJECT COLUMN, compared by the number inside it.
//
// `price` holds `{"cents":…}`. Before numeric paths, `scalar_of` dug a `$.value`
// that is not there and fell back to the whole JSON text, so Eq matched NOTHING
// — silently, because the fallback in `SqliteRepository::query` fires only when
// pushdown returns None, never when it returns an empty set. The ordered ops
// were dropped entirely, so they returned the whole store unnarrowed.
//
// The NULL row and the mis-shaped `{"value":7}` row are here on purpose: neither
// carries the declared path, so SQL cannot know their number, and the contract
// says a candidate set must never drop a row the dispatcher would keep.
fn priced(name: &str) -> SqliteRepository {
    let path = db_path(name);
    let _ = std::fs::remove_file(&path);
    let cols = vec![("price".to_string(), "TEXT".to_string())];
    let paths = HashMap::from([("price".to_string(), "cents".to_string())]);
    let mut repo = SqliteRepository::new("Pizza", &path, cols, paths).expect("open db");

    let mut cheap = AggregateState::new("cheap");
    cheap.set("price", Value::Map(HashMap::from([("cents".to_string(), Value::Int(1200))])));
    repo.save(cheap, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();

    let mut dear = AggregateState::new("dear");
    dear.set("price", Value::Map(HashMap::from([("cents".to_string(), Value::Int(2000))])));
    repo.save(dear, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();

    let unpriced = AggregateState::new("unpriced");
    repo.save(unpriced, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();

    let mut odd = AggregateState::new("odd");
    odd.set("price", Value::Map(HashMap::from([("value".to_string(), Value::Int(7))])));
    repo.save(odd, heki::WriteContext::OutOfBand { reason: "test" }).unwrap();

    repo
}

#[test]
fn a_value_object_column_agrees_with_the_oracle_on_every_comparator() {
    let repo = priced("priced_parity");
    let attrs = HashMap::new();
    for wheres in [
        vec![clause("price", WhereOp::Eq, "1200")],
        vec![clause("price", WhereOp::In, "1200, 9999")],
        vec![clause("price", WhereOp::Gt, "1500")],
        vec![clause("price", WhereOp::Gte, "2000")],
        vec![clause("price", WhereOp::Lt, "1500")],
        vec![clause("price", WhereOp::Lte, "1200")],
    ] {
        assert_parity(&repo, &wheres, &attrs);
    }
}

// Agreement alone would be satisfied by pushing nothing at all, so this asserts
// the narrowing actually happens. Both of these returned the WHOLE store before:
// Eq matched nothing and fell through, the ordered ops were dropped.
#[test]
fn a_value_object_column_actually_narrows_at_sql() {
    let repo = priced("priced_narrow");
    let attrs = HashMap::new();

    let equal = repo.query(&[clause("price", WhereOp::Eq, "1200")], &attrs);
    assert_eq!(raw_ids(&equal), vec!["cheap".to_string()], "eq narrows to the one row");

    // NULL and the mis-shaped row survive as candidates — SQL cannot know their
    // number, and dropping a row the dispatcher would keep is an under-return.
    let above = repo.query(&[clause("price", WhereOp::Gt, "1500")], &attrs);
    assert!(above.len() < repo.all().len(), "gt must narrow");
    assert!(raw_ids(&above).contains(&"dear".to_string()), "2000 > 1500");
    assert!(!raw_ids(&above).contains(&"cheap".to_string()), "1200 is not > 1500");
}

// A VALUE OBJECT WHOSE NUMBER IS NOT KEYED "value" — Money, Price, every amount
// the corpus declares. The oracle read a one-key map only by the literal key
// "value", so {"cents":2500} rendered as "{1 fields}" and byte-compared: '{'
// (0x7B) sorts above every digit, so Gt was ALWAYS true and Lt ALWAYS false,
// whatever the number was. These fail before the fix.
#[test]
fn where_matches_reads_a_value_object_by_its_number_not_its_key() {
    let attrs = HashMap::new();

    let mut priced = AggregateState::new("p1");
    let mut price: HashMap<String, Value> = HashMap::new();
    price.insert("cents".to_string(), Value::Int(2500));
    priced.set("price", Value::Map(price));

    let matches = |op, target| {
        storehouse::runtime::where_matches(&priced, &clause("price", op, target), &attrs)
    };
    assert!(!matches(WhereOp::Gt, "3000"), "2500 is not greater than 3000");
    assert!(matches(WhereOp::Lt, "3000"), "2500 is less than 3000");
    assert!(matches(WhereOp::Eq, "2500"), "2500 equals 2500");
}

// TWO fields, one of them numeric — banking's Money{cents, currency}. The rule is
// query_number's: exactly ONE numeric member, whatever it is called. Not Ruby's
// "first numeric in insertion order", which would be a coin flip here because
// Value::Map is a HashMap.
#[test]
fn where_matches_reads_the_one_numeric_member_of_a_two_field_value_object() {
    let attrs = HashMap::new();

    let mut account = AggregateState::new("a1");
    let mut money: HashMap<String, Value> = HashMap::new();
    money.insert("cents".to_string(), Value::Int(0));
    money.insert("currency".to_string(), Value::Str("USD".into()));
    account.set("balance", Value::Map(money));

    assert!(
        storehouse::runtime::where_matches(&account, &clause("balance", WhereOp::Lt, "1"), &attrs),
        "0 is less than 1"
    );
    assert!(
        !storehouse::runtime::where_matches(&account, &clause("balance", WhereOp::Gt, "1"), &attrs),
        "0 is not greater than 1"
    );
}

// A FLOAT — banking's DailyFee{amount: Float}. compare_strings parsed i64 only,
// so this fell to a byte compare where "10.5" sorts BELOW "9.0" on the first
// character. Asserted on a bare Float rather than through a value object, so the
// map reading cannot mask it: a Gt against 9.0 passed for the wrong reason while
// the oracle was broken, because "{1 fields}" byte-compares above every digit.
#[test]
fn where_matches_compares_a_float_as_a_number() {
    let attrs = HashMap::new();

    let mut card = AggregateState::new("c1");
    card.set("rate", Value::Float(10.5));

    assert!(
        storehouse::runtime::where_matches(&card, &clause("rate", WhereOp::Gt, "9.0"), &attrs),
        "10.5 is greater than 9.0"
    );
    assert!(
        !storehouse::runtime::where_matches(&card, &clause("rate", WhereOp::Lt, "9.0"), &attrs),
        "10.5 is not less than 9.0"
    );
}

// The same number inside a value object, asked the way the corpus asks it — a Lt
// that the broken reading gets WRONG. A Gt would have passed either way.
#[test]
fn where_matches_reads_a_float_member_of_a_value_object() {
    let attrs = HashMap::new();

    let mut card = AggregateState::new("c1");
    let mut fee: HashMap<String, Value> = HashMap::new();
    fee.insert("amount".to_string(), Value::Float(10.5));
    card.set("daily_fee", Value::Map(fee));

    assert!(
        storehouse::runtime::where_matches(&card, &clause("daily_fee", WhereOp::Lt, "11.0"), &attrs),
        "10.5 is less than 11.0"
    );
}

#[test]
fn injection_value_is_bound_not_executed() {
    let repo = seeded("injection");
    let attrs = HashMap::new();
    let wheres = vec![clause("status", WhereOp::Eq, EVIL)];
    let candidates = repo.query(&wheres, &attrs);
    let refs: Vec<&AggregateState> = candidates.iter().collect();
    assert_eq!(oracle_filter(&refs, &wheres, &attrs), vec!["5".to_string()]);
    assert_eq!(repo.all().len(), 5, "injection must not drop the table");
}
