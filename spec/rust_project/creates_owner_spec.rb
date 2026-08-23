require "spec_helper"
require_relative "../../rust/project"

# `creates_owner?` (rust/project/mutations.rb) replaced `command[:references]
# .nil?` as the "does this command build the owner record from scratch" test
# `rust/project/commands.rb#emit_command` and `identity_components` both
# consult, closing the Rust compile break RESTART.md describes: 12 meta-
# domain "attach one child to the owner" commands (`Aggregate.Attribute` et
# al.) each declare an argument coincidentally named the same as one of
# their OWNER's `identified_by` components (both have a field called
# `name`) while never setting the owner's own field — their one mutation
# APPENDS that argument into a list, sourced by it, which used to fool
# `identity_components`'s bare-name check into treating it as the owner's
# own id and misassigning it into the wrong-typed identity slot.
#
# UNEXERCISED BY THE ORDINARY SUITE ON PURPOSE — Ruby's own runtime stopped
# consulting `Command#creates?` for hydration this session
# (`CommandInterpreter#step_hydrate` uses `Runtime::DependencyPlanning::
# Analyzer` instead), so nothing in spec/*.rb exercises this exact path;
# only a Rust `cargo build` (or this spec) would have caught a wrong edit
# here. Fixtures below are plain projector-shaped hashes, the same input
# shape `bin/project_rust` itself feeds these methods — not full domain
# parses, matching `constraints_spec.rb`/`bridging_spec.rb`'s own reasoning
# for testing a pure codegen helper directly.
RSpec.describe RustProjection::Projector do
  # `Aggregate` (owner), `identified_by :bluebook, :name` — mirrors the real
  # meta-domain shape (aggregate.bluebook) that exposed this bug.
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

  # `Aggregate.Attribute` — attaches one attribute to an EXISTING Aggregate.
  # Declares its own `name`/`type` args, `name` coincidentally sharing the
  # owner's own identity component name, but its only mutation APPENDS them
  # into `:attributes` — it never sets the owner's own `:bluebook`/`:name`
  # fields at all.
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

  # `Aggregate.Declare` — genuinely mints a fresh Aggregate: every owner
  # field is an explicit `:set` mutation sourced from a same-named argument.
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
