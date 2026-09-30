require "spec_helper"
require "tmpdir"
require_relative "../../../lib/hecks/hecks/adapters/shell"

# The Shell port's adapter runs one program from an argument list and hands back what it said.
RSpec.describe Hecks::Adapters::Shell do
  let(:shell) { described_class.new }

  it "answers a program's stdout, stderr and status" do
    result = shell.capture("sh", "-c", "echo out; echo err >&2; exit 3")

    expect(result.out).to eq("out\n")
    expect(result.err).to eq("err\n")
    expect(result).not_to be_ok
  end

  it "answers success for a program that ends with status 0" do
    expect(shell.capture("true")).to be_ok
  end

  it "does not hand an argument to a shell to interpret" do
    expect(shell.capture("echo", "a; echo b").out).to eq("a; echo b\n")
  end

  it "sets and unsets environment variables for the program only" do
    result = shell.capture("sh", "-c", "echo $SHELL_SPEC_SET-${SHELL_SPEC_UNSET:-none}",
                           env: { "SHELL_SPEC_SET" => "x", "SHELL_SPEC_UNSET" => nil })

    expect(result.out).to eq("x-none\n")
    expect(ENV.key?("SHELL_SPEC_SET")).to be(false)
  end

  it "runs in the directory it is given" do
    Dir.mktmpdir("shell") do |dir|
      expect(File.realpath(shell.capture("pwd", chdir: dir).out.strip)).to eq(File.realpath(dir))
    end
  end

  it "answers a program that is not installed as a failure with a reason, not a raise" do
    result = shell.capture("no-such-program-anywhere")

    expect(result).not_to be_ok
    expect(result.err).to include("no-such-program-anywhere")
  end
end
