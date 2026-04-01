require "spec_helper"

RSpec.describe Hecks::Workshop::WorkshopRunner do
  let(:runner) { described_class.new }

  before do
    allow($stdout).to receive(:puts)
    runner.instance_variable_set(:@workshop, Hecks::Workshop.new("Test"))
  end

  describe "#aggregate" do
    it "delegates to workshop" do
      handle = runner.aggregate("Cat")
      expect(handle).to be_a(Hecks::Workshop::AggregateHandle)
    end

    it "normalizes lowercase names" do
      handle = runner.aggregate("cat")
      expect(handle.name).to eq("Cat")
    end
  end

  describe "named constants" do
    it "hoists aggregate as a named constant" do
      runner.aggregate("Cat")
      expect(described_class.const_get(:Cat)).to be_a(Hecks::Workshop::AggregateHandle)
    end

    after do
      Hecks::Utils.remove_constant(:Cat, from: described_class)
      Hecks::Utils.remove_constant(:Dog, from: described_class)
    end
  end

  describe "#help" do
    it "prints help text" do
      expect { runner.help }.to output(/Post.*create.*play!/m).to_stdout
    end

    it "returns nil" do
      expect(runner.help).to be_nil
    end
  end

  describe "#inspect" do
    it "shows mode in prompt" do
      expect(runner.inspect).to eq("hecks(test sketch)")
    end

    it "shows last event in prompt after play-mode execution" do
      runner.aggregate("Cat") { attribute :name, String; command("Meow") { attribute :name, String } }
      runner.play!
      mod = Object.const_get("TestDomain")
      mod::Cat.meow(name: "Henry")
      expect(runner.inspect).to match(/\[Meowed\]/)
    end
  end

  describe "#last_event" do
    it "returns nil in sketch mode" do
      expect(runner.last_event).to be_nil
    end

    it "returns the last event in play mode" do
      runner.aggregate("Cat") { attribute :name, String; command("Meow") { attribute :name, String } }
      runner.play!
      mod = Object.const_get("TestDomain")
      mod::Cat.meow(name: "Henry")
      expect(runner.last_event).not_to be_nil
    end
  end

  describe "delegated methods" do
    it "delegates validate" do
      runner.aggregate("Cat") { attribute :name, String; command("AdoptCat") { attribute :name, String } }
      expect(runner.validate).to be true
    end

    it "delegates describe" do
      runner.aggregate("Cat") { attribute :name, String }
      expect { runner.describe }.to output(/Test Domain/).to_stdout
    end

    it "delegates aggregates" do
      runner.aggregate("Cat")
      runner.aggregate("Dog")
      expect(runner.aggregates).to eq(["Cat", "Dog"])
    end

    it "delegates remove" do
      runner.aggregate("Cat")
      runner.remove("Cat")
      expect(runner.aggregates).to be_empty
    end

    it "delegates add_verb" do
      runner.add_verb("Poop")
      domain = runner.send(:instance_variable_get, :@workshop).to_domain
      expect(domain.custom_verbs).to include("Poop")
    end
  end
end
