require "spec_helper"
require_relative "../../rust/project/naming"
require_relative "../../rust/project/queries"

# gt/gte/lt/lte against a literal value used to be refused
# unconditionally — the stated reason ("Json::Num-vs-Json::Str fidelity
# this generator can't recover from the exported IR") went stale the
# moment WhereClause#to_h started rendering through Hecks::Literal.render
# (lib/hecks/literal.rb), which already round-trips Integer/Float/String/
# Bool/nil correctly; nobody had re-earned the refusal since. No real
# corpus query currently declares gt/gte/lt/lte (or eq/ne) against a
# NUMERIC-kind field with a literal value rather than a caller-bound
# Symbol arg (confirmed: every real corpus numeric comparison — balance
# gt/gte/lt/lte, pizza.price_cents.cents lt — uses an `Arg`), so this was
# entirely latent, real but unexercised by codegen_parity_spec's own
# corpus-based proof. Tested directly here instead of via a new fixture
# domain, same convention constraints_spec.rb already established.
RSpec.describe RustProjection::Projector do
  NUMERIC_ATTR_AGGREGATE = {
    attributes: [{ name: "balance", type: "Integer", list: false }]
  }.freeze

  STRING_ATTR_AGGREGATE = {
    attributes: [{ name: "status", type: "String", list: false }]
  }.freeze

  describe ".query_where_skip_reason" do
    it "no longer refuses gt against a literal targeting a numeric-kind field" do
      where = { field: "balance", op: "gt", value: "100" }

      reason = described_class.query_where_skip_reason(where, NUMERIC_ATTR_AGGREGATE, {})

      expect(reason).to be_nil
    end

    it "still refuses gt against a literal targeting a non-numeric field, with an accurate reason" do
      where = { field: "status", op: "gt", value: "100" }

      reason = described_class.query_where_skip_reason(where, STRING_ATTR_AGGREGATE, {})

      expect(reason).to include("kind: string")
      expect(reason).not_to include("Json::Num-vs-Json::Str") # the stale reason this fix retired
    end

    it "a numeric eq/ne literal is also no longer refused (the same fix closes both)" do
      where = { field: "balance", op: "eq", value: "100" }

      reason = described_class.query_where_skip_reason(where, NUMERIC_ATTR_AGGREGATE, {})

      expect(reason).to be_nil
    end

    it "leaves a string-kind eq literal exactly as accepted as before this fix" do
      where = { field: "status", op: "eq", value: "\"open\"" }

      reason = described_class.query_where_skip_reason(where, STRING_ATTR_AGGREGATE, {})

      expect(reason).to be_nil
    end
  end

  describe ".emit_query_condition_value" do
    it "emits NumericLiteral for a numeric-kind literal condition, never a bare Integer where Literal expects &str" do
      condition = { field: "balance", op: "gt", arg: nil, literal: 100 }

      expect(described_class.emit_query_condition_value(condition))
        .to eq("crate::kernel::QueryConditionValue::NumericLiteral(100.0)")
    end

    it "emits NumericLiteral for a Float literal too, with Ruby's own always-decimal Float#inspect spelling" do
      condition = { field: "balance", op: "gt", arg: nil, literal: 3.5 }

      expect(described_class.emit_query_condition_value(condition))
        .to eq("crate::kernel::QueryConditionValue::NumericLiteral(3.5)")
    end

    it "still emits Literal for a String condition, byte-identical to before this fix" do
      condition = { field: "status", op: "eq", arg: nil, literal: "open" }

      expect(described_class.emit_query_condition_value(condition))
        .to eq("crate::kernel::QueryConditionValue::Literal(\"open\")")
    end

    it "still emits Arg unaffected, regardless of the literal branch" do
      condition = { field: "balance", op: "gt", arg: "floor", literal: nil }

      expect(described_class.emit_query_condition_value(condition))
        .to eq("crate::kernel::QueryConditionValue::Arg(\"floor\")")
    end
  end
end
