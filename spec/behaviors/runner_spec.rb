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

  # THE `to:` COLLISION, PINNED — the fixture's own header comment has
  # the full story: MovePiece's destination fact is named `to`, the same
  # word Dispatcher#dispatch's routing envelope owns since #335, and the
  # runner once forwarded kwargs loose enough to collide ("to: does not
  # recognize file, rank" on the exact spelling the behaviors guide
  # promises). Every test passing here means the runner separates
  # identities from facts the same way a policy projection does.
  describe "a domain whose own command fact is named `to`" do
    let(:result) { described_class.run(fixture("board_moves.behaviors")) }

    it "runs every test through the envelope — setups and the tested dispatch alike" do
      expect(result.parse_error).to be_nil
      statuses = result.runs.to_h { |r| [r.description, [r.status, r.message]] }
      expect(statuses.values.map(&:first)).to all(eq(:pass)), statuses.inspect
    end
  end

  describe ".run_all" do
    it "sweeps every .behaviors file under a directory and reports how many it found" do
      sweep = described_class.run_all(File.expand_path("fixtures", __dir__))

      expect(sweep.files_swept).to eq(5)
      expect(sweep.summary[:parse_errors]).to eq(3) # no_vision, no_loads, no_op
    end
  end
end
