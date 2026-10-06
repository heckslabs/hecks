require "hecks"
require_relative "../../../lib/hecks/adapters/driven/claude_code"

# **Transport only** — never spawns the real `claude` binary (that would make
# this suite hit a live model on every run: slow, billed, non-deterministic).
# `Open3.capture2` is stubbed at the boundary; everything upstream of it
# (prompt construction, argv shape, envelope unwrapping) runs for real.
RSpec.describe Hecks::Adapters::ClaudeCode do
  let(:status) { instance_double(Process::Status, success?: true) }

  def envelope_for(hash) = JSON.generate({ "result" => JSON.generate(hash) })

  # Answers `reply` as the CLI's envelope for every call, and notes each call's argv and stdin.
  def stub_capture(reply)
    calls = []
    allow(Open3).to receive(:capture2) do |*argv, stdin_data:|
      calls << { argv: argv, stdin: stdin_data }
      [envelope_for(reply), status]
    end
    calls
  end

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
    it "spawns claude with -p, JSON output, and no tools, feeding the payload as stdin", :aggregate_failures do
      calls = stub_capture({ "proposals" => [] })

      result = described_class.call(system: "be terse", payload: { prose: "hello" })

      expect(result).to eq({ "proposals" => [] })
      expect(calls.first[:argv]).to include("claude", "-p", "--output-format", "json", "--allowedTools", "")
      expect(JSON.parse(calls.first[:stdin])).to eq({ "prose" => "hello" })
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
    it "ask" do
      calls = stub_capture({ "questions" => [] })

      described_class.ask(state: { chapter: "Loyalty" }, asked: ["x?"])

      expect(JSON.parse(calls.first[:stdin])).to eq({ "state" => { "chapter" => "Loyalty" }, "already_asked" => ["x?"] })
    end

    it "interpret" do
      calls = stub_capture({ "proposals" => [] })

      described_class.interpret(prose: "a member has a tier", state: {})

      expect(JSON.parse(calls.first[:stdin])).to eq({ "state" => {}, "prose" => "a member has a tier" })
    end

    it "critique names the closed kind vocabulary in its own system prompt" do
      calls = stub_capture({ "findings" => [] })
      described_class.critique(declared: {}, refusals: [], findings: [])
      argv = calls.first[:argv]

      expect(argv[argv.index("--append-system-prompt") + 1]).to include("crud_verb")
    end

    it "name" do
      calls = stub_capture({ "names" => [] })

      described_class.suggest_name(meaning: "a tier moved", kind: "event", near: ["Joined"])

      expect(JSON.parse(calls.first[:stdin])).to eq({ "meaning" => "a tier moved", "kind" => "event", "near" => ["Joined"] })
    end
  end
end
