// rust/tests/query_first_class_test.rs
//
// i101 — Queries are first-class IR.
//
// These tests exercise the structured query path end-to-end :
//   1. parse_blocks::parse_query reads `where / order_by / limit` clauses
//      out of a `query "Name" do … end` block into structured fields.
//   2. Runtime::resolve_query walks repo.all() applying the IR clauses
//      (filter → sort → truncate) instead of returning every record.
//
// The opaque-Ruby-block era is retired ; the runtime never executes a
// Ruby Proc at query time. Author intent is data, not code.

use hecks_life::ir::{Direction, WhereOp};
use hecks_life::parse_blocks::parse_query;
use hecks_life::parser;
use hecks_life::runtime::{Runtime, Value};
use std::collections::HashMap;

fn parse_one(source: &str) -> hecks_life::ir::Domain {
    parser::parse(source)
}

#[test]
fn parse_query_captures_eq_where_clause() {
    let source = r#"Hecks.bluebook "X" do
  aggregate "Book" do
    attribute :title,  String
    attribute :status, String

    query "Available" do
      where(status: "available")
    end
  end
end"#;
    let domain = parse_one(source);
    let book = &domain.aggregates[0];
    let q = &book.queries[0];
    assert_eq!(q.name, "Available");
    assert_eq!(q.wheres.len(), 1);
    assert_eq!(q.wheres[0].field, "status");
    assert!(matches!(q.wheres[0].op, WhereOp::Eq));
    assert_eq!(q.wheres[0].value, "available");
}

#[test]
fn parse_query_captures_block_param_as_kwarg_ref() {
    let source = r#"Hecks.bluebook "X" do
  aggregate "Book" do
    attribute :author, String

    query "ByAuthor" do |author|
      where(author: author)
    end
  end
end"#;
    let domain = parse_one(source);
    let q = &domain.aggregates[0].queries[0];
    assert_eq!(q.attributes.len(), 1, "block param became implicit attribute");
    assert_eq!(q.attributes[0].name, "author");
    assert_eq!(q.wheres.len(), 1);
    // Kwarg-ref form preserves the leading colon so the runtime
    // resolves :author against attrs at dispatch time.
    assert_eq!(q.wheres[0].value, ":author");
}

#[test]
fn parse_query_captures_order_by_and_limit() {
    let source = r#"Hecks.bluebook "X" do
  aggregate "Book" do
    attribute :title, String

    query "Recent" do
      order_by :title
      limit 5
    end
  end
end"#;
    let domain = parse_one(source);
    let q = &domain.aggregates[0].queries[0];
    let ob = q.order_by.as_ref().expect("order_by captured");
    assert_eq!(ob.field, "title");
    assert!(matches!(ob.direction, Direction::Asc));
    let ls = q.limit.as_ref().expect("limit captured");
    assert_eq!(ls.value, "5");
}

#[test]
fn parse_query_descending_order() {
    let source = r#"Hecks.bluebook "X" do
  aggregate "Book" do
    query "ByTitle" do
      order_by :title, :desc
    end
  end
end"#;
    let domain = parse_one(source);
    let ob = domain.aggregates[0].queries[0].order_by.as_ref().unwrap();
    assert!(matches!(ob.direction, Direction::Desc));
}

#[test]
fn parse_query_smoke_directly() {
    // Direct unit on parse_query (the path entered when the aggregate
    // parser sees `query "X" do`). The slice begins at the line that
    // opens the block ; the function returns (Query, lines_consumed).
    let lines = vec![
        "    query \"Active\" do",
        "      where(status: \"active\")",
        "      order_by :name",
        "      limit 10",
        "    end",
    ];
    let (q, consumed) = parse_query(&lines);
    assert_eq!(q.name, "Active");
    assert_eq!(consumed, 5);
    assert_eq!(q.wheres.len(), 1);
    assert!(q.order_by.is_some());
    assert!(q.limit.is_some());
}

#[test]
fn runtime_resolve_query_filters_by_where_clause() {
    let source = r#"Hecks.bluebook "Bookshelf" do
  aggregate "Book" do
    attribute :title,  String
    attribute :author, String
    attribute :status, String, default: "available"

    command "AddBook" do
      attribute :title,  String
      attribute :author, String
    end

    command "CheckOutBook" do
      reference_to Book
      then_set :status, to: "checked_out"
    end

    query "Available" do
      where(status: "available")
    end
  end
end"#;
    let domain = parse_one(source);
    let mut rt = Runtime::boot(domain);

    // Seed two books, check one out.
    let mut a = HashMap::new();
    a.insert("title".to_string(),  Value::Str("Dune".to_string()));
    a.insert("author".to_string(), Value::Str("Herbert".to_string()));
    let r1 = rt.dispatch("AddBook", a).unwrap();

    let mut b = HashMap::new();
    b.insert("title".to_string(),  Value::Str("Hyperion".to_string()));
    b.insert("author".to_string(), Value::Str("Simmons".to_string()));
    let _r2 = rt.dispatch("AddBook", b).unwrap();

    let mut c = HashMap::new();
    c.insert("book".to_string(), Value::Str(r1.aggregate_id.clone()));
    rt.dispatch("CheckOutBook", c).unwrap();

    let result = rt.resolve_query("Available", &HashMap::new());
    let state = &result["state"];
    // Only the second book remains in the available state — single-record
    // results render as a bare object (resolve_query unwraps len==1).
    assert!(!state.is_array(), "single record renders as object, not array");
    assert_eq!(state["title"].as_str(), Some("Hyperion"));
    assert_eq!(state["status"].as_str(), Some("available"));
}

#[test]
fn runtime_resolve_query_filters_by_kwarg_ref() {
    let source = r#"Hecks.bluebook "Bookshelf" do
  aggregate "Book" do
    attribute :title,  String
    attribute :author, String

    command "AddBook" do
      attribute :title,  String
      attribute :author, String
    end

    query "ByAuthor" do |author|
      where(author: author)
    end
  end
end"#;
    let domain = parse_one(source);
    let mut rt = Runtime::boot(domain);

    let mut a = HashMap::new();
    a.insert("title".to_string(),  Value::Str("Dune".to_string()));
    a.insert("author".to_string(), Value::Str("Herbert".to_string()));
    rt.dispatch("AddBook", a).unwrap();
    let mut b = HashMap::new();
    b.insert("title".to_string(),  Value::Str("Hyperion".to_string()));
    b.insert("author".to_string(), Value::Str("Simmons".to_string()));
    rt.dispatch("AddBook", b).unwrap();

    let mut attrs = HashMap::new();
    attrs.insert("author".to_string(), "Herbert".to_string());
    let result = rt.resolve_query("ByAuthor", &attrs);
    let state = &result["state"];
    // Single-record results render as a bare object, not an array.
    assert_eq!(state["title"].as_str(), Some("Dune"));
    assert_eq!(state["author"].as_str(), Some("Herbert"));
}

#[test]
fn runtime_resolve_query_applies_order_and_limit() {
    let source = r#"Hecks.bluebook "Bookshelf" do
  aggregate "Book" do
    attribute :title, String

    command "AddBook" do
      attribute :title, String
    end

    query "ByTitle" do
      order_by :title
      limit 2
    end
  end
end"#;
    let domain = parse_one(source);
    let mut rt = Runtime::boot(domain);

    for title in ["Charlie", "Alpha", "Bravo", "Delta"] {
        let mut a = HashMap::new();
        a.insert("title".to_string(), Value::Str(title.to_string()));
        rt.dispatch("AddBook", a).unwrap();
    }

    let result = rt.resolve_query("ByTitle", &HashMap::new());
    let records = result["state"].as_array().expect("array");
    assert_eq!(records.len(), 2, "limit 2 truncated the result set");
    assert_eq!(records[0]["title"].as_str(), Some("Alpha"));
    assert_eq!(records[1]["title"].as_str(), Some("Bravo"));
}
