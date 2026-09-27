require "spec_helper"
require_relative "../../rust/project/constraints"
require_relative "../../rust/project/exemplar"

# `optional:` combined with `pattern:`/`admits:` must wrap the check in `if let Some(..)`;
# a bare `Option<String>` handed to `pattern::matches` or `.contains` is a Rust compile error.
# Tested on the generated snippet directly: no corpus domain has this combination.
RSpec.describe RustProjection::Projector do
  REQUIRED_STRING_ATTR = { name: "description", type: "String", optional: false }.freeze
  OPTIONAL_STRING_ATTR = { name: "description", type: "String", optional: true }.freeze

  describe ".emit_pattern_check" do
    let(:attr) { OPTIONAL_STRING_ATTR.merge(pattern: "\\A\\S") }

    it "wraps an optional attribute's check in `if let Some(...) = &field`, never checking a bare Option" do
      generated = described_class.emit_pattern_check("self.description", attr, "Thing", {})

      expect(generated).to start_with("if let Some(__optional_value) = &self.description { ")
      expect(generated).to end_with(" }")
      # The check reads the rebound reference; the raw Option would not compile.
      expect(generated).to include("crate::kernel::pattern::matches(")
      expect(generated).to include("&__optional_value")
      expect(generated).not_to include("&self.description)")
    end

    it "leaves a REQUIRED attribute's check completely unwrapped, byte-identical to before this fix" do
      required = REQUIRED_STRING_ATTR.merge(pattern: "\\A\\S")

      generated = described_class.emit_pattern_check("self.description", required, "Thing", {})

      expect(generated).not_to include("if let Some")
      expect(generated).to include("&self.description")
    end
  end

  describe ".emit_admits_check" do
    let(:aggregates_by_name) do
      { "Thing" => { value_objects: [{ name: "Status", closed_set: true,
members: [[[:value, "open"]], [[:value, "closed"]]] }] } }
    end
    let(:attr) { OPTIONAL_STRING_ATTR.merge(name: "status", admits: "Thing::Status") }

    it "wraps an optional attribute's admits-check in `if let Some(...) = &field` too" do
      generated = described_class.emit_admits_check("self.status", attr, aggregates_by_name, {})

      expect(generated).to start_with("if let Some(__optional_value) = &self.status { ")
      expect(generated).to end_with(" }")
      expect(generated).to include(".contains(&__optional_value.as_str())")
    end

    it "leaves a REQUIRED attribute's admits-check unwrapped" do
      required = REQUIRED_STRING_ATTR.merge(name: "status", admits: "Thing::Status")

      generated = described_class.emit_admits_check("self.status", required, aggregates_by_name, {})

      expect(generated).not_to include("if let Some")
      expect(generated).to include(".contains(&self.status.as_str())")
    end
  end
end
