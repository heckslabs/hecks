# frozen_string_literal: true

require "spec_helper"
require_relative "support/creates_or_acts_fixture"

# `creates_or_acts` on a command: a creating command that acts on the record its identity already
# names instead of refusing it as taken. The Rust parser's reading of the fixture is held to this
# IR by spec/parser_parity_spec.rb, and the kernel's `Hydrate::CreateOrAct` by its guard tests.
RSpec.describe "creates_or_acts as declared" do
  include CreatesOrActsFixture

  around { |example| with_fixture_runtime(example) }

  it "says creates_or_acts on the command that declares it" do
    expect(command("Write").creates_or_acts?).to be(true)
  end

  it "leaves a command that does not say it creating only" do
    expect(command("Open").creates_or_acts?).to be(false)
  end

  it "plans the command as reading its occupant, so it never inserts only" do
    plan = Hecks::Runtime::DependencyPlanning::Analyzer.call(aggregate: page, command: command("Write"))
    expect(plan.state_independent?).to be(false)
  end
end
