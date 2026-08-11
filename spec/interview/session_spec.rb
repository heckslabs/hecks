require "spec_helper"
require "hecksagain/interview"
require_relative "../support/postgres_probe"

RSpec.describe Hecksagain::Interview::Session do
  # A FRESH SESSION PER EXAMPLE, against the REAL meta-domain — no double,
  # no stub. The whole point of dispatching into the language declared in
  # `lib/hecksagain/language/bluebook/` is that the language's own refusals
  # ARE the interview's feedback; a mock would just be asserting on
  # whatever this file made up.
  def session(chapter = "Loyalty") = described_class.open(chapter)

  it "opens with the chapter already declared, so 'not sealed yet' needs no special case" do
    s = session
    expect(s.declaration[:name]).to eq("Loyalty")
    expect(s.declaration[:aggregates]).to eq([])
  end

  describe "#offer" do
    it "accepts a well-formed declaration and it is visible in the reconstruction" do
      s = session
      verdict = s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })

      expect(verdict).to be_accepted
      expect(s.declaration[:aggregates].map { |a| a[:name] }).to eq(["Member"])
    end

    it "refuses in the LANGUAGE'S OWN WORDS, not a paraphrase" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      verdict = s.offer("Bluebook::Aggregate.Identify", id: "Loyalty:Member", path: { value: "just_a_name" })

      expect(verdict).not_to be_accepted
      expect(verdict.wants).to eq(:rule)
      expect(verdict.refusal).to include("an identity part reaches a scalar")
    end

    it "addresses a record by its single joined id, never by identity-head names — " \
       "several appenders (Attribute, Reference, Holds, Value) declare their OWN " \
       "'name' argument, which collides with the identity head of the same name" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      s.offer("Bluebook::ValueObject.Declare", aggregate_id: "Loyalty:Member", name: { value: "Points" })
      s.offer("Bluebook::Aggregate.Attribute", id: "Loyalty:Member",
              type: "Loyalty:Member:Points", name: { value: "points" }, list: { value: false })

      attribute = s.declaration[:aggregates].first[:attributes].first
      expect(attribute[:name]).to eq(:points) # not :Member — the collision this pins
    end

    it "parks a declaration that names a not-yet-declared prerequisite, as :prerequisite" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      verdict = s.offer("Bluebook::Aggregate.Attribute", id: "Loyalty:Member",
                         type: "Loyalty:Member:Points", name: { value: "points" }, list: { value: false })

      expect(verdict).not_to be_accepted
      expect(verdict.wants).to eq(:prerequisite)
      expect(verdict.refusal).to include("no ValueObject")
      expect(s.pending.map(&:verb)).to eq(["Bluebook::Aggregate.Attribute"])
    end

    it "drains a parked declaration automatically once its prerequisite is later declared" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      s.offer("Bluebook::Aggregate.Attribute", id: "Loyalty:Member",
              type: "Loyalty:Member:Points", name: { value: "points" }, list: { value: false })
      expect(s.pending).not_to be_empty

      s.offer("Bluebook::ValueObject.Declare", aggregate_id: "Loyalty:Member", name: { value: "Points" })

      expect(s.pending).to be_empty
      expect(s.declaration[:aggregates].first[:attributes].map { |a| a[:name] }).to eq([:points])
    end

    it "does NOT park a real rule refusal — retrying it later could never resolve it" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      s.offer("Bluebook::Aggregate.Identify", id: "Loyalty:Member", path: { value: "not_an_attribute" })

      expect(s.pending).to be_empty
    end

    it "classifies a duplicate declaration as :already_said, not a generic rule refusal" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      verdict = s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })

      expect(verdict.wants).to eq(:already_said)
    end

    it "refuses a verb the language does not declare, out loud — unlike Judge, which " \
       "tolerates one while walking a whole document" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      verdict = s.offer("Bluebook::Aggregate.Frobnicate", id: "Loyalty:Member")

      expect(verdict).not_to be_accepted
      expect(verdict.wants).to eq(:no_such_construct)
    end
  end

  describe "#gaps" do
    it "names an unsealed aggregate in the language's own refusal text" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })

      unsealed = s.gaps.find { |gap| gap.kind == :unsealed }
      expect(unsealed).not_to be_nil
      expect(unsealed.message).to include("an aggregate says what it is known by")
    end

    it "has no unsealed gap once identity is declared and Seal is offered" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      s.offer("Bluebook::ValueObject.Declare", aggregate_id: "Loyalty:Member", name: { value: "Points" })
      s.offer("Bluebook::Aggregate.Attribute", id: "Loyalty:Member",
              type: "Loyalty:Member:Points", name: { value: "points" }, list: { value: false })
      s.offer("Bluebook::Aggregate.Identify", id: "Loyalty:Member", path: { value: "points.value" })
      s.offer("Bluebook::Aggregate.Seal", id: "Loyalty:Member")

      expect(s.gaps.map(&:kind)).not_to include(:unsealed)
    end
  end

  describe "#assembled" do
    it "produces a real IR::Bluebook readable mid-interview, before anything is sealed" do
      s = session
      s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })

      expect(s.assembled.aggregates.map(&:hecks_name)).to eq(["Member"])
    end
  end

  it "keeps two chapters apart in the same process — different Session instances, " \
     "different isolated registries, no shared state" do
    a = session("Loyalty")
    b = session("Banking")
    a.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })

    expect(a.declaration[:aggregates].map { |x| x[:name] }).to eq(["Member"])
    expect(b.declaration[:aggregates]).to eq([])
  end

  # A real `Hecks.boot` on examples/pizzas, deliberately — the hazard this
  # proves survival of only exists if the "elsewhere" boot is a real one.
  # examples/pizzas' own .world declares `persisted_by("Postgres")`
  # unconditionally (support/postgres_probe.rb's own note), so this
  # genuinely needs a reachable Postgres carrying hecks_pizzas — `io: true`
  # and self-skipping otherwise, same as every other real-Postgres spec.
  it "survives a real Hecks.boot happening elsewhere in the process — the hazard " \
     "MetaValidator.fresh_runtime has and this class exists to avoid",
     io: true,
     skip: (PostgresProbe::AVAILABLE ? false : "no reachable Postgres — start one to run this spec") do
    s = session
    s.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })

    Hecks.boot(File.join(InMemoryDomain::ROOT, "examples/pizzas"))

    expect(s.declaration[:aggregates].map { |a| a[:name] }).to eq(["Member"])
  end
end
