require "hecks"
require "tmpdir"
require "fileutils"
require "socket"
require_relative "../../lib/hecks/quality_control/adapters/agent"

# The `Agent` adapter runs a real child process, so the agent here is a one-line Ruby script.
RSpec.describe Hecks::Adapters::Agent do
  # Ruby that answers "wrote" when the block it is given writes, and "denied" when the system
  # refuses.
  AGENT_TRY_SCRIPT = <<~RUBY.freeze
    def try
      yield
      "wrote"
    rescue SystemCallError
      "denied"
    end
  RUBY

  AGENT_SSH_PROBE = <<~RUBY.freeze
    begin
      Dir.children(File.join(Dir.home, ".ssh"))
      puts "read"
    rescue SystemCallError
      puts "denied"
    end
  RUBY

  # Ruby that dials a local port; `%<port>d` is the port.
  AGENT_NETWORK_PROBE = <<~RUBY.freeze
    require "socket"
    begin
      TCPSocket.new("127.0.0.1", %<port>d, connect_timeout: 3)
      puts "connected"
    rescue SystemCallError
      puts "denied"
    end
  RUBY

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

    it "takes QA_MINER_AGENT over the default, and the caller's own over both", :aggregate_failures do
      allow(ENV).to receive(:fetch).with("QA_MINER_AGENT", nil).and_return("from-env --flag")

      expect(adapter.command_for).to eq(["from-env", "--flag"])
      expect(adapter.command_for("mine --x")).to eq(["mine", "--x"])
      expect(adapter.command_for(%w[already split])).to eq(%w[already split])
    end
  end

  describe "asking" do
    it "hands the prompt over on standard input, in the directory it is given, and logs the output", :aggregate_failures do
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

    after { FileUtils.rm_f(marker) }

    def ruby_agent(body)
      "#{RbConfig.ruby} #{agent_script(body).split.last}"
    end

    # These run a real sandboxed child, so they exist only where a sandbox does (macOS). Left out
    # rather than skipped: CI has no such runner, and a skip there is a backstop failure.
    if Hecks::Adapters::AgentProfile.new.available?
      describe "confined by the sandbox" do
        def confined_ask(command, with: profile)
          adapter.ask(prompt: "p", command: command, chdir: @dir, profile: with).strip
        end

        def with_env_vars(vars)
          vars.each { |name, value| ENV[name] = value }
          yield
        ensure
          vars.each_key { |name| ENV.delete(name) }
        end

        def with_listening_server
          server = TCPServer.new("127.0.0.1", 0)
          yield server
        ensure
          server&.close
        end

        def write_attempts(inside)
          ruby_agent("#{AGENT_TRY_SCRIPT}puts try { File.write(#{marker.inspect}, \"x\") }\n" \
                     "puts try { File.write(#{inside.inspect}, \"x\") }\n")
        end

        it "refuses writes outside the directories it names, and allows the ones inside", :aggregate_failures do
          output = confined_ask(write_attempts(File.join(@dir, "inside")))

          expect(output.lines.map(&:strip)).to eq(%w[denied wrote])
          expect(File.exist?(marker)).to be(false)
        end

        it "refuses to read credentials" do
          expect(confined_ask(ruby_agent(AGENT_SSH_PROBE))).to eq("denied")
        end

        it "passes on only the environment variables the profile names" do
          with_env_vars("AGENT_SPEC_ALLOWED" => "yes", "AGENT_SPEC_SECRET" => "no") do
            command = ruby_agent('puts [ENV["AGENT_SPEC_ALLOWED"], ENV["AGENT_SPEC_SECRET"].inspect].join(" ")')

            expect(confined_ask(command)).to eq("yes nil")
          end
        end

        it "keeps the network shut unless the profile opens it", :aggregate_failures do
          with_listening_server do |server|
            command = ruby_agent(format(AGENT_NETWORK_PROBE, port: server.addr[1]))

            expect(confined_ask(command)).to eq("denied")
            expect(confined_ask(command, with: Hecks::Adapters::AgentProfile.new(network: :any, timeout: 10))).to eq("connected")
          end
        end

        it "stops an agent that runs past its timeout" do
          slow = Hecks::Adapters::AgentProfile.new(timeout: 1)

          expect { adapter.ask(prompt: "p", command: ruby_agent("sleep 30"), chdir: @dir, profile: slow) }
            .to raise_error(described_class::Failed, /timed out after 1s/)
        end
      end
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

    context "with confinement by the command's own permission rules" do
      let(:allowed) do
        Hecks::Adapters::AgentProfile.new(confinement: :permissions, tools: %w[Read Glob Write Edit],
                                          writable: [@dir], budget: 1.0)
      end

      it "has no sandbox in the way" do
        expect(allowed.sandboxed?).to be(false)
      end

      it "leaves the command as it was" do
        expect(allowed.confine(%w[claude -p])).to eq(%w[claude -p])
      end

      it "builds the default command from the profile's permission rules" do
        expect(adapter.command_for(nil, allowed)).to eq(
          ["claude", "-p", "--permission-mode", "dontAsk", "--tools", "Read,Glob,Write,Edit",
           "--allowedTools", "Read", "Glob", "Edit(/#{File.realpath(@dir)}/**)", "--strict-mcp-config",
           "--max-budget-usd", "1.0"]
        )
      end
    end

    it "refuses a command other than the default under permission confinement" do
      allowed = Hecks::Adapters::AgentProfile.new(confinement: :permissions, tools: %w[Read], writable: [@dir])

      expect { adapter.ask(prompt: "p", command: "true", chdir: @dir, profile: allowed) }
        .to raise_error(described_class::Failed, /applies only to the default claude command/)
    end

    it "rejects a confinement it does not know" do
      expect { Hecks::Adapters::AgentProfile.new(confinement: :hope) }.to raise_error(ArgumentError, /confinement must be/)
    end

    it "rejects a network setting it does not know" do
      expect { Hecks::Adapters::AgentProfile.new(network: :most) }.to raise_error(ArgumentError, /network must be/)
    end
  end
end
