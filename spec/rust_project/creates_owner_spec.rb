require "spec_helper"
require_relative "../../rust/project"

# `creates_owner?` decides whether a command builds the owner record from scratch. A command whose
# argument merely shares a name with an owner identity component (a list append) must not count.
# Fixtures are projector-shaped hashes, as `bin/project_rust` feeds them.
RSpec.describe RustProjection::Projector do
  # Owner shaped like the meta-domain's Aggregate, `identified_by :bluebook, :name`.
  CREATES_OWNER_SPEC_AGGREGATE = {
    name:          "Aggregate",
    identified_by: %w[bluebook name],
    lifecycle:     nil,
    attributes:    [
      { name: "bluebook",    type: "Reference<Bluebook>", list: false, optional: false, default: nil },
      { name: "name",        type: "AggregateName",       list: false, optional: false, default: nil },
      { name: "description", type: "Description",         list: false, optional: false, default: nil },
      { name: "attributes",  type: "Field", list: true, optional: false, default: nil }
    ]
  }.freeze

  # `Aggregate.Attribute` appends to `:attributes`; its `name` arg only coincides with an identity
  # component and it never sets the owner's own fields.
  CREATES_OWNER_SPEC_ATTACH_COMMAND = {
    name:       "Attribute",
    references: nil,
    attributes: [
      { name: "type", type: "Reference<ValueObject>", optional: false },
      { name: "name", type: "FieldName", optional: false }
    ],
    mutations:  [
      { target: "attributes", op: "append",
        fields: { "name" => ":name", "type" => ":type" } }
    ]
  }.freeze

  # `Aggregate.Declare` mints a fresh Aggregate: every owner field is `:set` from an argument.
  CREATES_OWNER_SPEC_DECLARE_COMMAND = {
    name:       "Declare",
    references: nil,
    attributes: [
      { name: "bluebook",    type: "Reference<Bluebook>", optional: false },
      { name: "name",        type: "AggregateName", optional: false },
      { name: "description", type: "Description", optional: true }
    ],
    mutations:  [
      { target: "bluebook",    op: "set", source: { kind: "argument", name: "bluebook" } },
      { target: "name",        op: "set", source: { kind: "argument", name: "name" } },
      { target: "description", op: "set", source: { kind: "argument", name: "description" } }
    ]
  }.freeze

  CREATES_OWNER_SPEC_VALUE_OBJECTS = {}.freeze

  describe ".creates_owner?" do
    it "says false for a command that only appends a coincidentally-named argument onto the owner's own list" do
      result = described_class.creates_owner?(CREATES_OWNER_SPEC_AGGREGATE, CREATES_OWNER_SPEC_ATTACH_COMMAND,
                                              CREATES_OWNER_SPEC_VALUE_OBJECTS)

      expect(result).to be(false)
    end

    it "says true for a command whose :set mutations cover every owner field" do
      result = described_class.creates_owner?(CREATES_OWNER_SPEC_AGGREGATE, CREATES_OWNER_SPEC_DECLARE_COMMAND,
                                              CREATES_OWNER_SPEC_VALUE_OBJECTS)

      expect(result).to be(true)
    end
  end

  describe ".identity_components" do
    it "treats a coincidentally-named argument as EXTERNAL when it never :sets the owner's own identity field" do
      components = described_class.identity_components(CREATES_OWNER_SPEC_AGGREGATE, CREATES_OWNER_SPEC_ATTACH_COMMAND)

      expect(components.map { |c| c[:param] }).to eq(["bluebook: &str", "name: &str"])
    end

    it "reads a genuinely creating command's identity straight off its own :set-sourced args" do
      components = described_class.identity_components(CREATES_OWNER_SPEC_AGGREGATE, CREATES_OWNER_SPEC_DECLARE_COMMAND)

      expect(components.map { |c| c[:param] }).to eq([nil, nil])
      expect(components.map { |c| c[:expr] }).to eq(["args.bluebook.to_string()", "args.name.to_string()"])
    end
  end
end
