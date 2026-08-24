require "hecks"
require_relative "../../../lib/hecks/adapters/driven/claude_code"

# TRANSPORT ONLY — never spawns the real `claude` binary (that would make
# this suite hit a live model on every run: slow, billed, non-deterministic).
# `Open3.capture2` is stubbed at the boundary; everything upstream of it
# (prompt construction, argv shape, envelope unwrapping) runs for real.
RSpec.describe Hecks::Adapters::ClaudeCode do
  def envelope_for(hash) = JSON.generate({ "result" => JSON.generate(hash) })

  describe ".unwrap" do
    it "parses the CLI envelope down to the model's own JSON reply" do
      stdout = envelope_for({ "questions" => [] })
      expect(described_class.unwrap(stdout)).to eq({ "questions" => [] })
    end

    it "refuses an envelope with no result key" do
      expect { described_class.unwrap(JSON.generate({ "cost" => 0.01 })) }
        .to raise_error(Hecks::Ports::Agent::ValidationError, /no "result"/)
    end

    it "refuses a result that is not JSON" do
      expect { described_class.unwrap(JSON.generate({ "result" => "sure, sounds good" })) }
        .to raise_error(Hecks::Ports::Agent::ValidationError, /not JSON/)
    end
  end

  describe ".call" do
    it "spawns claude with -p, JSON output, and no tools, feeding the payload as stdin" do
      status = instance_double(Process::Status, success?: true)
      expect(Open3).to receive(:capture2) do |*argv, stdin_data:|
        expect(argv).to include("claude", "-p", "--output-format", "json", "--allowedTools", "")
        expect(JSON.parse(stdin_data)).to eq({ "prose" => "hello" })
        [envelope_for({ "proposals" => [] }), status]
      end

      result = described_class.call(system: "be terse", payload: { prose: "hello" })
      expect(result).to eq({ "proposals" => [] })
    end

    it "raises Unavailable when the process exits non-zero" do
      status = instance_double(Process::Status, success?: false, exitstatus: 1)
      allow(Open3).to receive(:capture2).and_return(["boom", status])

      expect { described_class.call(system: "x", payload: {}) }
        .to raise_error(Hecks::Ports::Agent::Unavailable, /exited 1/)
    end

    it "raises Unavailable when the binary is missing" do
      allow(Open3).to receive(:capture2).and_raise(Errno::ENOENT.new("claude"))

      expect { described_class.call(system: "x", payload: {}) }
        .to raise_error(Hecks::Ports::Agent::Unavailable, /not on PATH/)
    end

    it "raises Unavailable when the call times out" do
      allow(Open3).to receive(:capture2) { sleep 0.2 }
      stub_const("Hecks::Adapters::ClaudeCode::TIMEOUT_SECONDS", 0.01)

      expect { described_class.call(system: "x", payload: {}) }
        .to raise_error(Hecks::Ports::Agent::Unavailable, /did not answer within/)
    end
  end

  describe "the four operations build a real, well-formed request" do
    let(:status) { instance_double(Process::Status, success?: true) }

    it "ask" do
      expect(Open3).to receive(:capture2) do |*, stdin_data:|
        expect(JSON.parse(stdin_data)).to eq({ "state" => { "chapter" => "Loyalty" }, "already_asked" => ["x?"] })
        [envelope_for({ "questions" => [] }), status]
      end
      described_class.ask(state: { chapter: "Loyalty" }, asked: ["x?"])
    end

    it "interpret" do
      expect(Open3).to receive(:capture2) do |*, stdin_data:|
        expect(JSON.parse(stdin_data)).to eq({ "state" => {}, "prose" => "a member has a tier" })
        [envelope_for({ "proposals" => [] }), status]
      end
      described_class.interpret(prose: "a member has a tier", state: {})
    end

    it "critique names the closed kind vocabulary in its own system prompt" do
      expect(Open3).to receive(:capture2) do |*argv, stdin_data:|
        system_prompt = argv[argv.index("--append-system-prompt") + 1]
        expect(system_prompt).to include("crud_verb")
        [envelope_for({ "findings" => [] }), status]
      end
      described_class.critique(declared: {}, refusals: [], findings: [])
    end

    it "name" do
      expect(Open3).to receive(:capture2) do |*, stdin_data:|
        expect(JSON.parse(stdin_data)).to eq({ "meaning" => "a tier moved", "kind" => "event", "near" => ["Joined"] })
        [envelope_for({ "names" => [] }), status]
      end
      described_class.suggest_name(meaning: "a tier moved", kind: "event", near: ["Joined"])
    end
  end
end
