require "hecks"
require "tmpdir"
require "fileutils"
require_relative "../../lib/hecks/quality_control/adapters/agent"

# The `Agent` adapter runs a real child process, so the agent here is a one-line Ruby script.
RSpec.describe Hecks::Adapters::Agent do
  subject(:adapter) { described_class.new }

  scratch_directory :dir, "agent_spec"

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

    it "takes QA_MINER_AGENT over the default, and the caller's own over both", :aggregate_failures do
      allow(ENV).to receive(:fetch).with("QA_MINER_AGENT", nil).and_return("from-env --flag")

      expect(adapter.command_for).to eq(["from-env", "--flag"])
      expect(adapter.command_for("mine --x")).to eq(["mine", "--x"])
      expect(adapter.command_for(%w[already split])).to eq(%w[already split])
    end
  end

  describe "asking" do
    it "hands the prompt over on standard input, in the directory it is given, and logs the output", :aggregate_failures,
       :process do
      log = File.join(@dir, "agent.log")
      command = agent_script("puts \"\#{Dir.pwd}: \#{$stdin.read}\"")

      output = adapter.ask(prompt: "write three domains", command: command, chdir: @dir, log: log)

      expect(output).to eq("#{File.realpath(@dir)}: write three domains\n")
      expect(File.read(log)).to eq(output)
    end

    it "says why an agent that ended in failure did", :process do
      command = agent_script('warn "out of tokens"; exit 3')

      expect { adapter.ask(prompt: "p", command: command, chdir: @dir) }
        .to raise_error(described_class::Failed, /agent exited 3: out of tokens/)
    end

    it "says so when there is no such agent to start", :process do
      expect { adapter.ask(prompt: "p", command: "no-such-agent-binary", chdir: @dir) }
        .to raise_error(described_class::Failed, /agent could not start \(no-such-agent-binary\)/)
    end
  end

  describe "with a profile" do
    let(:profile) { Hecks::Adapters::AgentProfile.new(env: ["AGENT_SPEC_ALLOWED"], timeout: 10) }

    # A confined run only accepts the default claude command, so these swap the default for a
    # Ruby script; what is under test is the environment, the timeout and the pipes.
    def ask_as_default(body, with: profile, prompt: "p")
      scripted = described_class.new
      allow(scripted).to receive(:default_command).and_return(agent_script(body).split)
      scripted.ask(prompt: prompt, chdir: @dir, profile: with)
    end

    def with_env_vars(vars)
      vars.each { |name, value| ENV[name] = value }
      yield
    ensure
      vars.each_key { |name| ENV.delete(name) }
    end

    it "passes on only the environment variables the profile names", :process do
      with_env_vars("AGENT_SPEC_ALLOWED" => "yes", "AGENT_SPEC_SECRET" => "no") do
        output = ask_as_default('puts [ENV["AGENT_SPEC_ALLOWED"], ENV["AGENT_SPEC_SECRET"].inspect].join(" ")')

        expect(output.strip).to eq("yes nil")
      end
    end

    it "stops an agent that runs past its timeout", :process do
      slow = Hecks::Adapters::AgentProfile.new(timeout: 1)

      expect { ask_as_default("sleep 30", with: slow) }
        .to raise_error(described_class::Failed, /timed out after 1s/)
    end

    it "does not deadlock when the agent writes before it has read a prompt larger than a pipe", :process do
      output = ask_as_default('puts "x" * 200_000; $stdin.read', prompt: "p" * 200_000)

      expect(output.length).to be > 200_000
    end

    it "builds the default command from the profile's tools and budget" do
      tools = Hecks::Adapters::AgentProfile.new(tools: %w[Read Grep], budget: 0.5)

      expect(adapter.command_for(nil, tools)).to eq(
        %w[claude -p --permission-mode dontAsk --tools Read,Grep --allowedTools Read Grep
           --strict-mcp-config --max-budget-usd 0.5]
      )
    end

    context "with writable directories" do
      let(:allowed) do
        Hecks::Adapters::AgentProfile.new(tools: %w[Read Glob Write Edit], writable: [@dir], budget: 1.0)
      end

      it "builds the default command from the profile's permission rules" do
        expect(adapter.command_for(nil, allowed)).to eq(
          ["claude", "-p", "--permission-mode", "dontAsk", "--tools", "Read,Glob,Write,Edit",
           "--allowedTools", "Read", "Glob", "Edit(/#{File.realpath(@dir)}/**)", "--strict-mcp-config",
           "--max-budget-usd", "1.0"]
        )
      end
    end

    it "refuses a command other than the default under a profile" do
      allowed = Hecks::Adapters::AgentProfile.new(tools: %w[Read], writable: [@dir])

      expect { adapter.ask(prompt: "p", command: "true", chdir: @dir, profile: allowed) }
        .to raise_error(described_class::Failed, /applies only to the default claude command/)
    end

    it "rejects a keyword it does not know" do
      expect { Hecks::Adapters::AgentProfile.new(network: :any) }.to raise_error(ArgumentError, /unknown keyword/)
    end
  end
end
