require "spec_helper"
require "tmpdir"
require "fileutils"

# A linked worktree that keeps no local files of its own loads its main checkout's, so its
# commands see the same dev databases. The spec runner never borrows, a worktree with its own
# files (the push train) keeps them, and a main checkout that may mint or archive is not lent.
RSpec.describe Hecks::Adapters::WorktreeBorrow do
  around { |example| Dir.mktmpdir { |base| (@base = base) && example.run } }

  let(:main) { File.join(@base, "main") }
  let!(:worktree) { build_worktree }
  let(:domain) { File.join(worktree, "lib/hecks/hecks") }

  describe ".from" do
    it "answers the main checkout when the worktree keeps no local file" do
      expect(described_class.from(domain, env: {})).to eq(main)
    end

    it "lends nothing to the spec runner" do
      expect(described_class.from(domain, env: { "HECKS_WRITES_LOCAL" => "1" })).to be_nil
    end

    it "lends nothing to a Memory environment" do
      expect(described_class.from(domain, env: { "HECKS_ENVIRONMENT" => "memory" })).to be_nil
    end

    it "lends nothing to a worktree that keeps its own overlay, as the push train does" do
      File.write(File.join(domain, "hecks.local.hecksagon"), "Hecks.hecksagon \"Hecks\" do\nend\n")
      expect(described_class.from(domain, env: {})).to be_nil
    end

    it "lends nothing when the main checkout's world may mint eras" do
      File.write(File.join(main, "lib/hecks/hecks/hecks.local.world"), "  mint_eras true\n")
      expect(described_class.from(domain, env: {})).to be_nil
    end

    it "answers nothing in the main checkout itself" do
      expect(described_class.from(File.join(main, "lib/hecks/hecks"), env: {})).to be_nil
    end
  end

  describe ".directory" do
    it "maps the worktree's domain directory onto the main checkout's" do
      expect(described_class.directory(domain, env: {})).to eq(File.join(main, "lib/hecks/hecks"))
    end

    it "lends nothing for a directory whose main local world archives its ledger" do
      File.write(File.join(main, "lib/hecks/hecks/pipeline.local.world"), "    disposable_ledger true\n")
      expect(described_class.directory(domain, env: {})).to be_nil
    end
  end

  describe "the worktree gap" do
    it "lists nothing missing while the worktree borrows" do
      expect(Hecks::Adapters::WorktreeOverlay.gap(domain, env: {})).to eq([main, []])
    end

    it "warns nothing for a Memory boot of a worktree that a default boot lends to" do
      expect(Hecks::Adapters::WorktreeOverlay.warning_for(domain, env: { "HECKS_ENVIRONMENT" => "memory" })).to be_nil
    end

    it "still lists the missing files for the spec runner" do
      expect(Hecks::Adapters::WorktreeOverlay.gap(domain).last).to eq(["lib/hecks/hecks/hecks.local.hecksagon"])
    end
  end

  describe "the overlay load" do
    it "loads the main checkout's local files for a borrowing worktree" do
      expect(loaded_directories(env: {})).to include(File.join(main, "lib/hecks/hecks"))
    end

    it "loads the worktree's own directory for the spec runner" do
      expect(loaded_directories(env: { "HECKS_WRITES_LOCAL" => "1" })).not_to include(File.join(main, "lib/hecks/hecks"))
    end
  end

  def loaded_directories(env:)
    loader = OverlayRecorder.new(env)
    loader.load_overlay(domain, nil)
    loader.directories
  end

  def build_worktree
    tree = File.join(@base, "wt")
    FileUtils.mkdir_p([File.join(main, ".git", "worktrees", "wt"), File.join(main, "lib/hecks/hecks"),
                       File.join(tree, "lib/hecks/hecks")])
    File.write(File.join(main, "lib/hecks/hecks/hecks.local.hecksagon"), "")
    File.write(File.join(tree, ".git"), "gitdir: #{File.join(main, ".git", "worktrees", "wt")}\n")
    tree
  end

  # Records the directories an overlay load reads its local files from.
  class OverlayRecorder
    include Hecks::Adapters::FolderOverlay

    # @return [Array<String>] each directory a load read from
    attr_reader :directories

    # @param env [Hash] the variables the borrow reads
    def initialize(env)
      @env = env
      @directories = []
    end

    # @return [Hash] the variables the borrow reads
    def overlay_env = @env

    # @param directory [String] where the files were looked for
    # @return [void]
    def load_each(directory, _patterns) = @directories << directory
  end
end
