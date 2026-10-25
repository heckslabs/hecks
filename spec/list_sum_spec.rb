# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "a sum over a list" do
  let(:expression) { Hecks::Bluebook::Expression }
  let(:state) do
    { items: [{ quantity: 2, price: 40 }, { quantity: 1, price: 25 }], none: [], rates: [{ rate: 1.5 }, { rate: 2 }] }
  end

  def holds?(text) = expression::Evaluator.interpret(expression::Evaluator.parse(text), state, {})

  it "adds what the block works out for each element" do
    expect(holds?("items.sum { |i| i.quantity * i.price } == 105")).to be(true)
  end

  it "answers 0 for an empty list" do
    expect(holds?("none.sum { |i| i.price } == 0")).to be(true)
  end

  it "adds a mix of whole and fractional numbers" do
    expect(holds?("rates.sum { |r| r.rate } == 3.5")).to be(true)
  end

  it "refuses a block that is a test, not a number" do
    expect { holds?("items.sum { |i| i.price > 1 } == 2") }
      .to raise_error(expression::EvaluationError, /addition expects a number/)
  end

  it "refuses a receiver that is not a list" do
    expect { holds?("items.sum { |i| i.price }.sum { |j| j } == 1") }
      .to raise_error(expression::EvaluationError)
  end

  describe "the AST" do
    let(:text) { "items.sum { |i| i.price } >= 10" }
    let(:ast) { expression::AstJson.emit_predicate(text) }

    it "names the sum, its parameter and its block" do
      expect(ast["left"]).to include("op" => "sum", "param" => "i")
    end

    it "reads back as the node it was written from" do
      expect(expression::AstReader.read_predicate(ast)).to eq(expression::Evaluator.parse(text))
    end
  end
end
