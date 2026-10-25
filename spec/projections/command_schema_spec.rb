require "spec_helper"
require_relative "../support/booted_source"
require_relative "../support/json_schema_subset"

# The command schema describes what a command's payload may hold. Its check of a payload must agree
# with what the runtime's argument stage says, or a client would be told one thing locally and
# another by the server.
RSpec.describe Hecks::Projections::CommandSchema do
  CRATE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Crating" do
      aggregate "Crate" do
        identified_by :tag
        attribute :tag,    Tag
        attribute :size,   Size
        attribute :price,  Price
        attribute :kind,   Kind
        attribute :labels, list_of(Label)
        attribute :note,   Note, optional: true
        value_object("Tag")   { attribute :value, String, matches: :present }
        value_object("Size")  { attribute :value, Integer }
        value_object("Price") { attribute :cents, Integer; attribute :currency, String, default: "USD" }
        value_object("Kind")  { attribute :name, String, one_of: %w[small large] }
        value_object("Label") { attribute :value, String }
        value_object("Note")  { attribute :value, String }
        command("Pack") do
          role "Packer"
          goal "Pack a crate"
          attribute :tag,    Tag
          attribute :size,   Size
          attribute :price,  Price
          attribute :kind,   Kind
          attribute :labels, list_of(Label)
          attribute :note,   Note, optional: true
          given("the size is positive") { size.value > 0 }
          sets :tag
          sets :size
          sets :price
          sets :kind
          sets :labels
          emits "CratePacked"
        end
      end
    end
  BLUEBOOK

  let(:dispatcher) do
    BootedSource.boot(CRATE_SOURCE, authorization: true) do
      Hecks.hecksagon("Crating") do
        attaches "Governance"
        Crating::Crate.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
  end

  let(:files) { described_class.call(bluebook: dispatcher.registry.bluebook("Crating")) }
  let(:schema) { JSON.parse(files.fetch("Crating/Crate/Pack.schema.json")) }
  let(:good) { { tag: "c1", size: 2, price: { cents: 5 }, kind: "small", labels: ["a"] } }

  def schema_accepts?(payload) = JsonSchemaSubset.valid?(schema, payload)

  def argument_refusals(payload)
    dispatcher.validate("Crating::Crate.Pack", payload).refusals.select { |refusal| refusal.stage == :arguments }
  end

  it "registers as a projection" do
    expect(Hecks::Projector.registered?(:command_schema)).to be(true)
  end

  it "writes one schema file per command" do
    expect(files.keys).to eq(["Crating/Crate/Pack.schema.json"])
  end

  it "names the draft, the verb and the goal", :aggregate_failures do
    expect(schema.slice("$schema", "title", "description")).to eq(
      "$schema" => "https://json-schema.org/draft/2020-12/schema", "title" => "Crating::Crate.Pack",
      "description" => "Pack a crate"
    )
  end

  it "requires what the runtime requires, and not the optional or defaulted", :aggregate_failures do
    expect(schema["required"]).to match_array(%w[tag size price kind labels])
    expect(schema["properties"]["price"]["required"]).to eq(["cents"])
  end

  it "allows a single-field value object bare or as an object, and a group only as an object", :aggregate_failures do
    expect(schema_accepts?(good)).to be(true)
    expect(schema_accepts?(good.merge(tag: { value: "c1" }))).to be(true)
    expect(schema_accepts?(good.merge(price: 5))).to be(false)
  end

  it "carries what a schema cannot check as annotations", :aggregate_failures do
    expect(schema["x-role"]).to eq("Packer")
    expect(schema["x-givens"]).to include(a_hash_including("description" => "the size is positive"))
    expect(schema["x-emits"]).to eq(["CratePacked"])
  end

  def accepted_variants
    [good, good.merge(tag: { value: "c1" }), good.merge(note: "n"), good.merge(price: { cents: 5, currency: "EUR" })]
  end

  def refused_variants
    [good.merge(size: "2"), good.merge(kind: "huge"), good.except(:size), good.merge(bogus: 1),
     good.merge(price: { cents: "5" }), good.merge(labels: "a"), good.merge(tag: "")]
  end

  def payloads = accepted_variants + refused_variants

  it "agrees with the runtime's argument stage on every payload tried" do
    disagreements = payloads.reject { |payload| schema_accepts?(payload) == argument_refusals(payload).empty? }

    expect(disagreements).to be_empty
  end
end
