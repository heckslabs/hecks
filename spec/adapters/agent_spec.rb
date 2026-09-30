require "hecks"
require "tmpdir"
require_relative "../../lib/hecks/quality_control/adapters/agent"

# The `Agent` adapter runs a real child process, so the agent here is a one-line Ruby script.
RSpec.describe Hecks::Adapters::Agent do
  subject(:adapter) { described_class.new }

  around do |example|
    Dir.mktmpdir("agent_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def agent_script(body)
    path = File.join(@dir, "agent.rb")
    File.write(path, body)
    "ruby #{path}"
  end

  describe "the command it runs" do
    it "defaults to claude -p with edit tools" do
      allow(ENV).to receive(:fetch).with("QA_MINER_AGENT", nil).and_return(nil)

      expect(adapter.command_for).to eq(described_class::DEFAULT_COMMAND)
    end

    it "takes QA_MINER_AGENT over the default, and the caller's own over both" do
      allow(ENV).to receive(:fetch).with("QA_MINER_AGENT", nil).and_return("from-env --flag")

      expect(adapter.command_for).to eq(["from-env", "--flag"])
      expect(adapter.command_for("mine --x")).to eq(["mine", "--x"])
      expect(adapter.command_for(%w[already split])).to eq(%w[already split])
    end
  end

  describe "asking" do
    it "hands the prompt over on standard input, in the directory it is given, and logs the output" do
      log = File.join(@dir, "agent.log")
      command = agent_script("puts \"\#{Dir.pwd}: \#{$stdin.read}\"")

      output = adapter.ask(prompt: "write three domains", command: command, chdir: @dir, log: log)

      expect(output).to eq("#{File.realpath(@dir)}: write three domains\n")
      expect(File.read(log)).to eq(output)
    end

    it "says why an agent that ended in failure did" do
      command = agent_script('warn "out of tokens"; exit 3')

      expect { adapter.ask(prompt: "p", command: command, chdir: @dir) }
        .to raise_error(described_class::Failed, /agent exited 3: out of tokens/)
    end

    it "says so when there is no such agent to start" do
      expect { adapter.ask(prompt: "p", command: "no-such-agent-binary", chdir: @dir) }
        .to raise_error(described_class::Failed, /agent could not start \(no-such-agent-binary\)/)
    end
  end
end
