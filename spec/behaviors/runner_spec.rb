require "hecksagain/behaviors"

RSpec.describe Hecksagain::Behaviors do
  def fixture(name) = File.join(File.expand_path("fixtures", __dir__), name)

  describe "parse errors" do
    it "names the fix for a missing vision" do
      result = described_class.run(fixture("no_vision.behaviors"))
      expect(result.parse_error).to include("no `vision")
    end

    it "names the fix for a missing loads" do
      result = described_class.run(fixture("no_loads.behaviors"))
      expect(result.parse_error).to include("no `loads")
    end

    it "reports a file that loads without ever calling Hecks.behaviors" do
      result = described_class.run(fixture("no_op.behaviors"))
      expect(result.parse_error).to eq("file loaded but called no Hecks.behaviors")
    end

    it "refuses Hecks.behaviors called outside the runner" do
      expect { Hecks.behaviors("Direct") { vision "x" } }.to raise_error(Hecksagain::Behaviors::LoadOutsideRunner)
    end
  end

  describe "a sweep that never confuses a stale suite for a fresh one" do
    it "does not let a no-op file after a real one reuse the prior suite" do
      real  = described_class.run(fixture("pizzas_edge_cases.behaviors"))
      no_op = described_class.run(fixture("no_op.behaviors"))

      expect(real.parse_error).to be_nil
      expect(no_op.parse_error).to eq("file loaded but called no Hecks.behaviors")
    end
  end

  describe "one test, start to finish" do
    let(:runs) do
      described_class.run(fixture("pizzas_edge_cases.behaviors")).runs.to_h { |r| [r.description, r] }
    end

    it "reports a setup refusal as an error, never a fail or a pass" do
      run = runs.fetch("a setup refusal is an error, never a fail or a pass")
      expect(run.status).to eq(:error)
      expect(run.message).to include('setup "CreatePizza" refused')
    end

    it "sees a policy cascade in emits:, in order" do
      run = runs.fetch("emits sees a policy cascade through a port operation, in order")
      expect(run.status).to eq(:pass)
    end

    it "fails an unknown expect field, naming the five valid keys" do
      run = runs.fetch("an unknown expect field fails, naming the five valid keys")
      expect(run.status).to eq(:fail)
      expect(run.message).to include("ok:, refused:, emits:, count:")
    end

    it "accepts both the bare and the wrapped value-object spelling" do
      run = runs.fetch("a field expectation accepts both the bare and the wrapped value-object spelling")
      expect(run.status).to eq(:pass)
    end
  end

  describe ".run_all" do
    it "sweeps every .behaviors file under a directory and reports how many it found" do
      sweep = described_class.run_all(File.expand_path("fixtures", __dir__))

      expect(sweep.files_swept).to eq(4)
      expect(sweep.summary[:parse_errors]).to eq(3) # no_vision, no_loads, no_op
    end
  end
end
