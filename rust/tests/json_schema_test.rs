//! JSON Schema projection tests — the payload contract, published.
//!
//! One canonical schema per command, from the IR : one_of → enum,
//! required → required, wrapper VO → inner type, reference → id string,
//! stray-key rule → additionalProperties:false. The served form and
//! external validators both read this ; the payload gate enforces it.

use storehouse::parser;
use storehouse::projection::json_schema;

const SHED: &str = r##"Hecks.bluebook "SchemaShed" do
  aggregate "Tool" do
    attribute :name, ToolName
    attribute :daily_fee, Fee
    attribute :standing, one_of("good", "suspended"), default: "good"
    attribute :currency, Currency

    value_object "ToolName" do
      attribute :value, String
    end
    value_object "Fee" do
      attribute :cents, Integer
      invariant "non-negative" do cents >= 0 end
    end
    value_object "Currency" do
      attribute :code, String
      attribute :symbol, String
      one_of do
        member code: "USD", symbol: "$"
        member code: "JPY", symbol: "¥"
      end
    end

    command "AddTool" do
      role "Owner"
      attribute :name, ToolName, required: true
      attribute :daily_fee, Fee, required: true
      attribute :standing, one_of("good", "suspended"), default: "good"
      attribute :currency, Currency
    end
  end
end"##;

fn schema_for(command: &str) -> serde_json::Value {
    let domain = parser::parse(SHED);
    let agg = &domain.aggregates[0];
    let cmd = agg.commands.iter().find(|c| c.name == command).unwrap();
    json_schema::command_schema(agg, cmd)
}

#[test]
fn wrapper_vo_maps_to_inner_primitive() {
    let s = schema_for("AddTool");
    // Fee wraps Integer cents → integer ; ToolName wraps String → string.
    assert_eq!(s["properties"]["daily_fee"]["type"], "integer");
    assert_eq!(s["properties"]["name"]["type"], "string");
}

#[test]
fn one_of_scalar_maps_to_enum() {
    let s = schema_for("AddTool");
    let en = &s["properties"]["standing"]["enum"];
    assert_eq!(en[0], "good");
    assert_eq!(en[1], "suspended");
}

#[test]
fn one_of_members_map_to_discriminant_enum() {
    let s = schema_for("AddTool");
    let en = &s["properties"]["currency"]["enum"];
    assert_eq!(en[0], "USD");
    assert_eq!(en[1], "JPY");
}

#[test]
fn wrapper_vo_invariant_becomes_minimum() {
    // Fee wraps Integer cents with `cents >= 0` → minimum 0 : the form
    // renders min="0" so a negative can't be typed. The invariant becomes
    // a schema keyword.
    let s = schema_for("AddTool");
    assert_eq!(s["properties"]["daily_fee"]["minimum"], 0);
}

#[test]
fn required_and_additional_properties() {
    let s = schema_for("AddTool");
    let req = s["required"].as_array().unwrap();
    assert!(req.iter().any(|v| v == "name"));
    assert!(req.iter().any(|v| v == "daily_fee"));
    // standing has a default → not required.
    assert!(!req.iter().any(|v| v == "standing"));
    assert_eq!(s["additionalProperties"], false);
}
