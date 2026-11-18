# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# The Fixer's guards on an attempt's recorded reproduction test a missing value with
# `.value == nil`, which is true for a missing field. `nil?` is false for one in a rule, so a
# guard written with it never stops on a missing reproduction.
RSpec.describe "The Fixer's guards on an attempt's reproduction" do
  include MissingValueGuards

  let(:attempt) { MissingValueGuards.bluebook("lib/hecks/fixer", "Fixer").aggregate("Attempt") }
  let(:failed) { { reproduction: { value: "bin/repro" }, reproduced: { value: "failed" } } }

  def guard(command, phrase)
    given_of(attempt.commands.find { |held| held.hecks_name == command }, phrase)
  end

  it "lets Fix through only with a failing reproduction on the record", :aggregate_failures do
    fix = guard("Fix", "reproduction")
    expect(holds?(fix, failed)).to be(true)
    MissingValueGuards::MISSING.each { |gone| expect(holds?(fix, failed.merge(reproduced: gone))).to be(false) }
  end

  it "keeps a merge as pending while no failing reproduction is recorded", :aggregate_failures do
    note = guard("NoteMerge", "reproduction")
    expect(holds?(note, failed)).to be(false)
    MissingValueGuards::MISSING.each { |gone| expect(holds?(note, failed.merge(reproduction: gone))).to be(true) }
  end

  it "verifies only a re-run of the recorded reproduction", :aggregate_failures do
    verify = guard("Verify", "rerun.value")
    expect(holds?(verify, failed.merge(rerun: { value: "bin/repro" }))).to be(true)
    expect(holds?(verify, failed.merge(reproduction: { value: nil }, rerun: { value: nil }))).to be(false)
  end
end
