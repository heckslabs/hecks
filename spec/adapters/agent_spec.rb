require "hecks"
require "tmpdir"
require "fileutils"
require "socket"
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

  describe "with a profile" do
    let(:profile) { Hecks::Adapters::AgentProfile.new(env: ["AGENT_SPEC_ALLOWED"], timeout: 10) }
    let(:marker) { File.join(Dir.home, ".agent_spec_marker_#{Process.pid}") }

    before { skip "no sandbox on this machine" unless profile.available? }
    after { FileUtils.rm_f(marker) }

    def ruby_agent(body)
      "#{RbConfig.ruby} #{agent_script(body).split.last}"
    end

    it "refuses writes outside the directories it names, and allows the ones inside" do
      inside = File.join(@dir, "inside")
      command = ruby_agent(<<~RUBY)
        def try
          yield
          "wrote"
        rescue SystemCallError
          "denied"
        end
        puts try { File.write(#{marker.inspect}, "x") }
        puts try { File.write(#{inside.inspect}, "x") }
      RUBY

      output = adapter.ask(prompt: "p", command: command, chdir: @dir, profile: profile)

      expect(output.lines.map(&:strip)).to eq(%w[denied wrote])
      expect(File.exist?(marker)).to be(false)
    end

    it "refuses to read credentials" do
      command = ruby_agent(<<~RUBY)
        begin
          Dir.children(File.join(Dir.home, ".ssh"))
          puts "read"
        rescue SystemCallError
          puts "denied"
        end
      RUBY

      expect(adapter.ask(prompt: "p", command: command, chdir: @dir, profile: profile).strip).to eq("denied")
    end

    it "passes on only the environment variables the profile names" do
      ENV["AGENT_SPEC_ALLOWED"] = "yes"
      ENV["AGENT_SPEC_SECRET"] = "no"
      command = ruby_agent('puts [ENV["AGENT_SPEC_ALLOWED"], ENV["AGENT_SPEC_SECRET"].inspect].join(" ")')

      expect(adapter.ask(prompt: "p", command: command, chdir: @dir, profile: profile).strip).to eq("yes nil")
    ensure
      ENV.delete("AGENT_SPEC_ALLOWED")
      ENV.delete("AGENT_SPEC_SECRET")
    end

    it "keeps the network shut unless the profile opens it" do
      server = TCPServer.new("127.0.0.1", 0)
      command = ruby_agent(<<~RUBY)
        require "socket"
        begin
          TCPSocket.new("127.0.0.1", #{server.addr[1]}, connect_timeout: 3)
          puts "connected"
        rescue SystemCallError
          puts "denied"
        end
      RUBY
      open_profile = Hecks::Adapters::AgentProfile.new(network: :any, timeout: 10)

      expect(adapter.ask(prompt: "p", command: command, chdir: @dir, profile: profile).strip).to eq("denied")
      expect(adapter.ask(prompt: "p", command: command, chdir: @dir, profile: open_profile).strip).to eq("connected")
    ensure
      server&.close
    end

    it "stops an agent that runs past its timeout" do
      slow = Hecks::Adapters::AgentProfile.new(timeout: 1)

      expect { adapter.ask(prompt: "p", command: ruby_agent("sleep 30"), chdir: @dir, profile: slow) }
        .to raise_error(described_class::Failed, /timed out after 1s/)
    end

    it "refuses to run unconfined where there is no sandbox" do
      allow(profile).to receive(:available?).and_return(false)

      expect { adapter.ask(prompt: "p", command: "true", chdir: @dir, profile: profile) }
        .to raise_error(described_class::Failed, /refusing to run an agent unconfined/)
    end

    it "builds the default command from the profile's tools and budget" do
      tools = Hecks::Adapters::AgentProfile.new(tools: %w[Read Grep], budget: 0.5)

      expect(adapter.command_for(nil, tools)).to eq(
        %w[claude -p --permission-mode acceptEdits --tools Read,Grep --allowedTools Read,Grep --max-budget-usd 0.5]
      )
    end

    it "rejects a network setting it does not know" do
      expect { Hecks::Adapters::AgentProfile.new(network: :most) }.to raise_error(ArgumentError, /network must be/)
    end
  end
end
