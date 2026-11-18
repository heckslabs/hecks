# frozen_string_literal: true

require "spec_helper"

# `x.nil?` is false for a missing value in a rule, so a guard that stops on it never stops. Rules
# refuse it at load and name `== nil`. The refusal is a Ruby load-time check; the Rust evaluator
# still reads `x.nil?` as an ordinary lookup (`rust/host/core/src/expr_json.rs`).
RSpec.describe "A rule that tests a value with nil?" do
  let(:ast_json) { Hecks::Bluebook::Expression::AstJson }

  def refuse(canonical)
    ast = ast_json.emit_predicate(canonical)
    ast_json.refuse_unresolvable_lookups!(ast, owner: "Run", word: "given")
  end

  it "is refused, and the message names == nil" do
    expect { refuse("tries.nil? || tries.value < 3") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Write `tries == nil` instead/)
  end

  it "is refused under a negation", :aggregate_failures do
    expect { refuse("!ended_at.nil? && ended_at.value == 0") }.to raise_error(Hecks::Bluebook::DSL::Malformed, /nil\?/)
    expect { refuse("run.verdict.nil?") }.to raise_error(Hecks::Bluebook::DSL::Malformed, /run\.verdict == nil/)
  end

  it "lets the == nil test through" do
    expect(refuse("tries == nil || tries.value < 3")).to be_a(Hash)
  end

  it "answers the == nil test true for a missing value and false for a present one", :aggregate_failures do
    evaluator = Hecks::Bluebook::Expression::Evaluator
    expect(evaluator.call("tries == nil", { tries: nil })).to be(true)
    expect(evaluator.call("tries == nil", { tries: { value: 1 } })).to be(false)
  end
end
