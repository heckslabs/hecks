require "rbconfig"
require "tmpdir"
require "hecks/release/runner"

# The real command runner, exercised with Ruby itself as the command so no git,
# gem, npm or network is involved.
RSpec.describe Hecks::Release::Runner::Commands do
  subject(:commands) { described_class.new }

  let(:ruby) { RbConfig.ruby }

  it "captures output and reports success", :aggregate_failures do
    result = commands.capture(ruby, "-e", "print 'out'; warn 'err'")

    expect(result).to be_success
    expect(result.stdout).to eq("out")
    expect(result.stderr).to eq("err\n")
  end

  it "reports a non-zero exit as a failed result rather than raising" do
    expect(commands.capture(ruby, "-e", "exit 3")).not_to be_success
  end

  it "reports a command that cannot start as a failed result carrying the reason", :aggregate_failures do
    result = commands.capture("hecks-no-such-tool-#{Process.pid}", "--version")

    expect(result).not_to be_success
    expect(result.stderr).not_to be_empty
  end

  it "runs in the directory it is given" do
    Dir.mktmpdir do |dir|
      result = commands.capture(ruby, "-e", "print Dir.pwd", chdir: dir)

      expect(File.realpath(result.stdout)).to eq(File.realpath(dir))
    end
  end

  it "sets and unsets environment variables for the child only", :aggregate_failures do
    result = commands.capture(ruby, "-e", "print ENV['HECKS_RELEASE_SPEC'].inspect", env: { "HECKS_RELEASE_SPEC" => "1" })

    expect(result.stdout).to eq('"1"')
    expect(ENV.key?("HECKS_RELEASE_SPEC")).to be(false)
  end

  it "run! returns true for a zero exit" do
    expect(commands.run!(ruby, "-e", "exit 0")).to be(true)
  end

  it "run! raises CommandFailed for a non-zero exit and for a command that cannot start", :aggregate_failures do
    expect { commands.run!(ruby, "-e", "exit 1") }.to raise_error(Hecks::Release::Runner::CommandFailed)
    expect { commands.run!("hecks-no-such-tool-#{Process.pid}") }.to raise_error(Hecks::Release::Runner::CommandFailed)
  end
end
