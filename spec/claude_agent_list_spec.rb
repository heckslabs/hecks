require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/claude_agents"

# The agents a session can start are read in its own directory and in the repository's main
# checkout, and a directory `claude` does not trust is refused by name.
module AgentListFixtures
  Answer = Struct.new(:out, :err)

  # Answers each directory with the text saved for it, and records where it was asked.
  class AskedShell
    attr_reader :asked

    def initialize(answers)
      @answers = answers
      @asked = []
    end

    def capture(*_command, chdir:, **)
      @asked << chdir
      Answer.new(@answers.fetch(chdir, ""), "")
    end
  end

  def git(dir, *) = system("git", "-C", dir, *, out: File::NULL, err: File::NULL, exception: true)

  # A repository with a linked worktree, as [main, worktree].
  def repository_with_worktree(dir)
    main = File.realpath(dir)
    git(main, "init", "-q", "-b", "main")
    git(main, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
    git(main, "worktree", "add", "-q", "-b", "item", File.join(main, "item"))
    [main, File.join(main, "item")]
  end

  def shell_for(answers) = AskedShell.new(answers)

  def listing(shell) = Hecks::Adapters::ClaudeAgentList.new("claude", shell: shell)

  def failure = Hecks::Adapters::ConsoleCapture::Failure
end

RSpec.describe Hecks::Adapters::ClaudeAgentList do
  include AgentListFixtures

  around do |example|
    Dir.mktmpdir do |dir|
      @main, @tree = repository_with_worktree(dir)
      example.run
    end
  end

  it "joins the agents of a linked worktree with the main checkout's", :aggregate_failures do
    shell = shell_for(@tree => "Available agents: general-purpose", @main => "Available agents: coder, planner")
    expect(listing(shell).names(@tree)).to eq(%w[general-purpose coder planner])
    expect(shell.asked).to eq([@tree, @main])
  end

  it "asks once in a directory that is its own main checkout", :aggregate_failures do
    shell = shell_for(@main => "Available agents: coder")
    expect(listing(shell).names(@main)).to eq(%w[coder])
    expect(shell.asked).to eq([@main])
  end

  it "refuses a directory whose workspace is not trusted, by name" do
    shell = shell_for(@tree => "Error: Workspace not trusted")
    expect { listing(shell).names(@tree) }.to raise_error(failure, /#{Regexp.escape(@tree)} is not a trusted workspace/)
  end

  it "refuses an answer that names no list" do
    shell = shell_for(@tree => "something reworded")
    expect { listing(shell).names(@tree) }.to raise_error(failure, /listed no agents/)
  end
end
