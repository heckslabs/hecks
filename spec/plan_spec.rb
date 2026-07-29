
require "spec_helper"

# The plan is read from the language, so these are assertions ABOUT THE LANGUAGE
# as much as about the reader. If bluebook.bluebook renames a list or moves an
# append onto a different command, one of these fails — which is the point: the
# judge is about to be driven by this, and a wrong plan is a silent judge.
RSpec.describe Hecksagain::Bluebook::MetaValidator::Plan do
  def plan
    @plan ||= described_class.for(Hecksagain::Bluebook::MetaValidator.grammar_registry)
  end

  describe "the containment tree, recovered from the declarations" do
    it "finds Bluebook to be the root" do
      expect(plan.category("Bluebook")).to be_root
      expect(plan.category("Bluebook").parent).to be_nil
    end

    it "reads each category's parent off the creating command's reference" do
      parents = plan.names.to_h { |name| [name, plan.category(name).parent] }

      expect(parents).to eq(
        "Bluebook"       => nil,
        "Aggregate"      => "Bluebook",
        "Command"        => "Aggregate",
        "ValueObject"    => "Aggregate",
        "Query"          => "Aggregate",
        "Entity"         => "Aggregate",
        "Member"         => "ValueObject",
        "Policy"         => "Bluebook",
        "ProcessManager" => "Bluebook",
        "Handler"        => "ProcessManager",
        "Dispatch"       => "Handler",
        "ReadModel"      => "Bluebook"
      )
    end

    it "leaves out a category that declares no commands" do
      # Vocabulary is static declaration read straight from the IR by
      # spec/vocabulary_conformance_spec. Nothing to offer, so nothing to plan.
      expect(plan.names).not_to include("Vocabulary")
    end
  end

  describe "the append table — the thing said to be underivable" do
    it "finds the appender for each of a command's lists, by target and not by name" do
      # The list names ARE the IR's reader names — `givens`, not `rules` — so the
      # walk reads a built command straight through with no table in between.
      # The VERB keeps the language's own word for the act (Rule, Change), which
      # is not a name the walk ever has to match.
      appends = plan.category("Command").appends

      expect(appends.keys).to match_array(%w[attributes givens mutations emits])
      expect(appends["attributes"].verb).to eq("Argument")
      expect(appends["givens"].verb).to eq("Rule")
      expect(appends["mutations"].verb).to eq("Change")
    end

    it "carries the field -> argument map, so an element can be shaped into a dispatch" do
      expect(plan.category("Command").appends["givens"].map)
        .to eq(description: :description, canonical: :canonical)
    end

    it "keeps a map whose names differ on the two sides" do
      # Announce is the only append in the language whose value-object field and
      # command argument are spelled differently — and it stays that way even
      # under one spelling, because `emits` is a list of bare strings while the
      # Announcement value object has to call that string something. A walk that
      # assumed identity would drop every emitted event and nothing would go red.
      expect(plan.category("Command").appends["emits"].map).to eq(name: :announces)
    end
  end

  describe "setters and sealers" do
    it "reads a setter that writes two fields in one command" do
      lifecycle = plan.category("Aggregate").setters.find { |setter| setter.verb == "Lifecycle" }

      expect(lifecycle.targets).to eq("state_field" => "state_field", "state_start" => "state_start")
    end

    it "reads a setter whose argument is named differently from its target" do
      # ActsOn takes `root`, not `references` : a command argument SHADOWS the
      # aggregate field of the same name inside a given, so the once-only rule
      # could not read the state it guards if the two matched. This is the one
      # place a differing name is REQUIRED rather than incidental.
      acts_on = plan.category("Command").setters.find { |setter| setter.verb == "ActsOn" }

      expect(acts_on.targets).to eq("references" => "root")
    end

    it "finds the whole-document command that changes nothing" do
      expect(plan.category("Aggregate").sealers).to eq(["Seal"])
    end
  end

  describe "the fields the creating command carries" do
    it "lists them without the parent link" do
      expect(plan.category("Command").fields).to eq(%w[name role goal])
      expect(plan.category("Command").parent_key).to eq("aggregate_id")
    end
  end

  it "names every verb the language declares, and no others" do
    declared = Hecksagain::Bluebook::MetaValidator.grammar_registry
                 .bluebook("Meta").aggregates
                 .flat_map { |a| a.commands.map { |c| "Meta::#{a.name}.#{c.name}" } }

    expect(plan.verbs).to match_array(declared)
  end
end
