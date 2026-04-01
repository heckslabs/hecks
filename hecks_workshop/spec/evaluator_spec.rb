require "spec_helper"

RSpec.describe Hecks::Workshop::WebRunner::Evaluator do
  let(:runner) do
    r = Hecks::Workshop::WorkshopRunner.new(name: "TestDomain")
    r.instance_variable_set(:@workshop, r.setup_workshop)
    r
  end
  let(:evaluator) { described_class.new(runner) }

  before { allow($stdout).to receive(:puts) }

  describe "#evaluate" do
    it "executes bare commands" do
      result = evaluator.evaluate("describe")
      expect(result[:error]).to be_nil
    end

    it "creates aggregates" do
      evaluator.evaluate("Pizza")
      expect(runner.instance_variable_get(:@workshop).aggregates).to include("Pizza")
    end

    it "calls handle methods" do
      evaluator.evaluate("Order")
      result = evaluator.evaluate("Order.describe")
      expect(result[:error]).to be_nil
    end

    it "adds attributes" do
      evaluator.evaluate("Order")
      evaluator.evaluate("Order.attr :total, Integer")
      result = evaluator.evaluate("Order.attributes")
      expect(result[:output]).to include("total")
    end

    it "rejects unknown methods" do
      evaluator.evaluate("Pizza")
      result = evaluator.evaluate("Pizza.send :system")
      expect(result[:error]).to include("Unknown method")
    end

    it "rejects non-PascalCase targets" do
      result = evaluator.evaluate("file.read")
      # lowercase target doesn't match grammar — not a bare command or aggregate
      expect(result[:output]).not_to include("/")
    end
  end
end
