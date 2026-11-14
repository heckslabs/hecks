require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/claude_executable"
require "hecks/hecks/adapters/claude_resolving_shell"

# Finding `claude` without it being on the caller's path, and refusing by name when it is nowhere.
RSpec.describe Hecks::Adapters::ClaudeExecutable do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def program(*parts)
    File.join(@dir, *parts).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#!/bin/sh\n")
      File.chmod(0o755, path)
    end
  end

  it "keeps `claude` when the PATH holds it" do
    program("bin", "claude")

    expect(described_class.new(candidates: [], path: File.join(@dir, "bin")).resolve).to eq("claude")
  end

  it "finds claude in a declared candidate when the PATH lacks it" do
    place = program("home", ".local", "bin", "claude")

    expect(described_class.new(candidates: ["/nowhere/claude", place], path: "/nowhere").resolve).to eq(place)
  end

  it "refuses by name when the PATH and every candidate lack it", :aggregate_failures do
    executable = described_class.new(candidates: ["/nowhere/claude"], path: "/nowhere")

    expect { executable.resolve }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure,
                                                 "claude is not on the path and none of /nowhere/claude exists")
    expect(executable.found?).to be(false)
  end

  describe Hecks::Adapters::ClaudeResolvingShell do
    let(:shell) { instance_double(Hecks::Adapters::Shell, capture: :said) }
    let(:executable) { instance_double(Hecks::Adapters::ClaudeExecutable, resolve: "/home/.local/bin/claude") }
    let(:resolving) { described_class.new(executable: executable, shell: shell) }

    it "runs claude from where it was found, behind a nice prefix too", :aggregate_failures do
      resolving.capture("claude", "agents", "--json")
      resolving.capture("nice", "-n", "15", "claude", "--bg", "--", "claude")

      expect(shell).to have_received(:capture).with("/home/.local/bin/claude", "agents", "--json", env: {}, chdir: nil)
      expect(shell).to have_received(:capture).with("nice", "-n", "15", "/home/.local/bin/claude", "--bg", "--", "claude",
                                                    env: {}, chdir: nil)
    end

    it "leaves another program alone" do
      resolving.capture("git", "status")

      expect(shell).to have_received(:capture).with("git", "status", env: {}, chdir: nil)
    end
  end
end
