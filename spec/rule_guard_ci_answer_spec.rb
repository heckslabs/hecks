# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# Early CI records a green run when CI names no failing job and a red one when it names some, and
# takes an answer only for the record's own head. The rules test a missing value with
# `.value == nil`.
RSpec.describe "The EarlyCi rules on a missing failing list and head" do
  include MissingValueGuards

  let(:hecks) { MissingValueGuards.bluebook("lib/hecks/hecks", "Hecks") }

  def recorded(failing)
    %w[RecordTheGreenRun RecordTheRedRun]
      .map { |name| fires?(hecks.policies.find { |held| held.hecks_name == name }, { failing: failing }) }
  end

  def answers?(sha, of_sha)
    observe = hecks.aggregate("EarlyCi").commands.find { |held| held.hecks_name == "Observe" }
    Hecks::Bluebook::Expression::Evaluator.call_rule(given_of(observe, "of_sha"), { sha: sha }, { of_sha: of_sha })
  end

  it "records a run with no failing job as green", :aggregate_failures do
    [nil, { value: nil }, { value: "" }].each { |none| expect(recorded(none)).to eq([true, false]) }
  end

  it "records a run with a failing job as red" do
    expect(recorded({ value: "rspec_1" })).to eq([false, true])
  end

  it "takes an answer for a record with no head, or for its own head only", :aggregate_failures do
    expect(MissingValueGuards::MISSING.map { |sha| answers?(sha, { value: "abc" }) }).to eq([true, true])
    expect(answers?({ value: "abc" }, { value: "abc" })).to be(true)
    expect(answers?({ value: "abc" }, { value: "def" })).to be(false)
  end
end
