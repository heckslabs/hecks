require "stringio"
require "hecks/release/runner"
require "hecks/release/runner/clean_tree"
require "hecks/release/runner/gem_publisher"
require_relative "support/recording_commands"

# What a release ships must be exactly what is committed: ignored files count, build output
# does not, and the gem push refuses a dirty tree on its own.
RSpec.describe Hecks::Release::Runner::CleanTree do
  let(:commands) { ReleaseSpecSupport::RecordingCommands.new(sha: "a" * 40, version: "9.9.9") }
  let(:git) { Hecks::Release::Runner::Git.new(root: Dir.pwd, commands: commands) }
  let(:ignored) { ["git", "status", "--porcelain", "--ignored", "--", *Hecks::Release::Runner::CleanTree::SHIPPED] }

  it "asks git for ignored files under the packaged paths only" do
    described_class.new(git: git).check!

    expect(commands.argvs).to include(ignored)
  end

  it "passes a tree with nothing stray, and ignores build output" do
    commands.answer(*ignored, stdout: "!! rust/target/\n!! rust/web/target/\n")

    expect(described_class.new(git: git).stray).to be_empty
  end

  it "refuses an ignored file under lib/, which `git status --porcelain` never shows" do
    commands.answer(*ignored, stdout: "!! lib/hecks/secret_notes.rb\n?? rust/scratch.rs\n M lib/hecks.rb\n")

    expect { described_class.new(git: git).check! }
      .to raise_error(Hecks::Release::Runner::Refusal, %r{3 file\(s\).*lib/hecks/secret_notes\.rb.*rust/scratch\.rs})
  end

  describe "the gem step" do
    it "refuses to push a gem from a tree with a stray file, before building anything" do
      commands.answer(*ignored, stdout: "!! lib/leftover.rb\n")
      console = Hecks::Release::Runner::Console.new(input: StringIO.new, out: StringIO.new, err: StringIO.new)
      publisher = Hecks::Release::Runner::GemPublisher.new(root: Dir.pwd, commands: commands, console: console)

      expect { publisher.publish!("9.9.9", dry_run: false) }
        .to raise_error(Hecks::Release::Runner::Refusal, %r{lib/leftover\.rb})
      expect(commands.runs).to be_empty
    end
  end
end
