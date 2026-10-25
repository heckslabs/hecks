# frozen_string_literal: true

require "spec_helper"
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

  it "is read by hecks-parse into the IR Ruby exports, byte for byte", :io do
    binary = File.expand_path("../rust/parser/target/debug/hecks-parse", __dir__)
    skip "build rust/parser first" unless File.exist?(binary)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "cart.bluebook")
      File.write(path, <<~RUBY)
        Hecks.bluebook "Cart" do
          vision "A cart holds priced lines."

          aggregate "Cart" do
            description "A cart a customer fills."
            identified_by :number

            attribute :number, CartNumber
            attribute :lines, list_of(Line)

            value_object "CartNumber" do
              attribute :value, String
            end

            value_object "Line" do
              attribute :price, Integer
              attribute :quantity, Integer
            end

            command "Open" do
              attribute :number, CartNumber
              given("the lines stay within the limit") { lines.sum { |l| l.quantity * l.price } <= 1000 }
            end
          end
        end
      RUBY
      rust, err, = Open3.capture3(binary, "chapter", "--chapter", "Cart", path)
      registry = Hecks::Runtime::Registry.new(root: dir)
      Hecks.with_registry(registry) do
        MemoryPorts.load!
        Kernel.load(path)
      end
      ruby = "#{JSON.pretty_generate(Hecks::Projector::Exporter.call(registry).fetch("Cart"))}\n"

      expect(err).to be_empty
      expect(rust).to include('"op": "sum"')
      expect(rust).to eq(ruby)
    end
  end

  it "emits the AST the Rust parser and generator read" do
    ast = expression::AstJson.emit_predicate("items.sum { |i| i.price } >= 10")
    expect(ast["left"]).to include("op" => "sum", "param" => "i")
    expect(expression::AstReader.read_predicate(ast)).to eq(expression::Evaluator.parse("items.sum { |i| i.price } >= 10"))
  end
end
