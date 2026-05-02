# spec/hecks/runtime/prompt_scaffolder_spec.rb
#
# Contract for Hecks::Runtime::PromptScaffolder. Exercises the
# i23 §6 :command_metadata scaffold shape, system + persona
# blending, PII stripping (i23 §10 risk 3), loop-guard stripping
# (i23 §10 risk 7), and SHA256 hash-stability across two builds
# of the same input.
#
# Synthetic in-memory IR — no full Hecksagon boot needed. Target:
# < 100ms total spec runtime ; pre-commit hook enforces the global
# 1s spec-suite ceiling.
#
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks"

RSpec.describe Hecks::Runtime::PromptScaffolder do
  # Synthetic IR helpers — keep specs hermetic + cheap. We build
  # the minimal Aggregate + Command shape the scaffolder reads.
  def attribute(name, type: String, pii: false)
    Hecks::BluebookModel::Structure::Attribute.new(name: name, type: type, pii: pii)
  end

  def precondition(message)
    Hecks::BluebookModel::Behavior::Condition.new(message: message, block: ->(_) { true })
  end

  def aggregate(name, attrs = [])
    Hecks::BluebookModel::Structure::Aggregate.new(name: name, attributes: attrs)
  end

  def command(name, description: nil, preconditions: [], sets: {}, attrs: [])
    Hecks::BluebookModel::Behavior::Command.new(
      name: name,
      description: description,
      preconditions: preconditions,
      sets: sets,
      attributes: attrs,
    )
  end

  describe ".build" do
    let(:curator) do
      aggregate("Curator", [
        attribute(:idea, type: String),
        attribute(:response, type: String),
        attribute(:status, type: String),
      ])
    end

    let(:curate_cmd) do
      command(
        "CurateMusing",
        description: "Generate a minted musing from a seed idea.",
        preconditions: [precondition("idea is present"), precondition("status is :open")],
        sets: { status: "minted" },
        attrs: [attribute(:idea, type: String)],
      )
    end

    it "produces the §6 :command_metadata SYSTEM + USER shape" do
      result = described_class.build(
        command:   curate_cmd,
        aggregate: curator,
        attrs:     { idea: "snow falling on cedars" },
        scaffold:  :command_metadata,
      )

      expect(result.text).to include("SYSTEM:")
      expect(result.text).to include("You are dispatching the Curator.CurateMusing command.")
      expect(result.text).to include("Description: Generate a minted musing from a seed idea.")
      expect(result.text).to include("When to fire: idea is present AND status is :open")
      expect(result.text).to include("On success, you will set: status=minted")
      expect(result.text).to include("State fields in scope: idea, response, status")
      expect(result.text).to include("USER:")
      expect(result.text).to include("idea: snow falling on cedars")
    end

    it "blends adapter system + persona ahead of the scaffold block" do
      result = described_class.build(
        command:   curate_cmd,
        aggregate: curator,
        attrs:     { idea: "snow" },
        scaffold:  :command_metadata,
        system:    "You are Miette. Be concise.",
        persona:   "Tone: gentle, French.",
      )

      sys = result.system
      expect(sys.index("You are Miette. Be concise.")).to be < sys.index("Tone: gentle, French.")
      expect(sys.index("Tone: gentle, French.")).to be < sys.index("You are dispatching")
    end

    it "omits scaffold block when scaffold: is nil but keeps system/persona" do
      result = described_class.build(
        command:   curate_cmd,
        aggregate: curator,
        attrs:     { idea: "snow" },
        scaffold:  nil,
        system:    "Be terse.",
      )
      expect(result.system).to eq("Be terse.")
      expect(result.text).not_to include("You are dispatching")
      expect(result.text).to include("USER:\nidea: snow")
    end

    it "strips PII attributes flagged on the aggregate's own Attribute#pii?" do
      pii_agg = aggregate("Patient", [
        attribute(:name, type: String),
        attribute(:ssn,  type: String, pii: true),
      ])
      result = described_class.build(
        command:   command("UpdatePatient"),
        aggregate: pii_agg,
        attrs:     { name: "Alice", ssn: "123-45-6789" },
      )
      expect(result.user).to include("name: Alice")
      expect(result.user).not_to include("123-45-6789")
      expect(result.user).not_to include("ssn:")
    end

    it "strips PII attributes flagged via aggregate_capabilities" do
      result = described_class.build(
        command:                curate_cmd,
        aggregate:              curator,
        attrs:                  { idea: "ok", response: "leak" },
        aggregate_capabilities: { "Curator" => [{ attribute: "response", tag: :pii }] },
      )
      expect(result.user).to include("idea: ok")
      expect(result.user).not_to include("response:")
      expect(result.user).not_to include("leak")
    end

    it "strips on_response-targeted attrs (i23 §10 risk 7 loop guard)" do
      result = described_class.build(
        command:           curate_cmd,
        aggregate:         curator,
        attrs:             { idea: "seed", response: "previous LLM output" },
        on_response_attrs: [:response],
      )
      expect(result.user).to include("idea: seed")
      expect(result.user).not_to include("response:")
      expect(result.user).not_to include("previous LLM output")
    end

    it "is hash-stable: same input → same SHA256 across two builds" do
      args = {
        command:   curate_cmd,
        aggregate: curator,
        attrs:     { idea: "a", status: "b" },
        scaffold:  :command_metadata,
        system:    "S",
        persona:   "P",
      }
      a = described_class.build(**args)
      b = described_class.build(**args)
      expect(a.sha256).to eq(b.sha256)
      expect(a.text).to eq(b.text)
    end

    it "is hash-stable across reordered attrs hashes" do
      a = described_class.build(
        command: curate_cmd, aggregate: curator,
        attrs: { idea: "x", status: "y" }, scaffold: :command_metadata,
      )
      b = described_class.build(
        command: curate_cmd, aggregate: curator,
        attrs: { status: "y", idea: "x" }, scaffold: :command_metadata,
      )
      expect(a.sha256).to eq(b.sha256)
    end

    it "tolerates string keys in attrs (still stable)" do
      a = described_class.build(
        command: curate_cmd, aggregate: curator,
        attrs: { "idea" => "x" },
      )
      b = described_class.build(
        command: curate_cmd, aggregate: curator,
        attrs: { idea: "x" },
      )
      expect(a.sha256).to eq(b.sha256)
    end

    it "joins multiple guard messages with ' AND ' deterministically (sorted)" do
      cmd = command(
        "Foo",
        preconditions: [precondition("zeta-check"), precondition("alpha-check")],
      )
      result = described_class.build(
        command: cmd, aggregate: aggregate("X"),
        attrs: {}, scaffold: :command_metadata,
      )
      expect(result.system).to include("When to fire: alpha-check AND zeta-check")
    end

    it "includes only the bare command name when aggregate is nil" do
      cmd = command("StandaloneCmd", description: "no aggregate")
      result = described_class.build(
        command: cmd, aggregate: nil, attrs: {}, scaffold: :command_metadata,
      )
      expect(result.system).to include("dispatching the StandaloneCmd command")
      expect(result.system).not_to include(".StandaloneCmd")
    end

    it "produces an empty USER section when sanitised attrs is empty" do
      result = described_class.build(
        command: curate_cmd, aggregate: curator, attrs: {},
      )
      expect(result.user).to eq("")
      expect(result.text).not_to include("USER:")
    end

    it "returns a non-empty hex SHA256 for any non-empty prompt" do
      result = described_class.build(
        command: curate_cmd, aggregate: curator,
        attrs: { idea: "x" }, scaffold: :command_metadata,
      )
      expect(result.sha256).to match(/\A[0-9a-f]{64}\z/)
    end
  end
end
