# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/hecks/adapters/landing/worktree_scratch"

# Helpers that build a throwaway git repository in `tree`.
module ScratchRepoHelpers
  def git(*) = Open3.capture2e("git", "-C", tree, *)

  def put(path, text = "x")
    FileUtils.mkdir_p(File.dirname(File.join(tree, path)))
    File.write(File.join(tree, path), text)
  end

  def repo(ignore: "tmp/\n.ruby-lsp/\ntarget/\n")
    git("init", "-q", "-b", "main")
    put(".gitignore", ignore)
    put("tracked.rb")
    git("add", ".")
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "seed")
  end

  def with_scratch
    repo
    put("tmp/a.log")
    put("rust/kernel/target/debug/x")
  end

  def with_tracked_file
    repo(ignore: "tmp/*.log\n")
    put("tmp/keep.rb")
    git("add", "-f", "tmp/keep.rb")
    put("tmp/a.log")
  end
end

# The scratch a finished run's worktree leaves behind, cleared only where git says it is ignored.
RSpec.describe Hecks::Adapters::WorktreeScratch do
  include ScratchRepoHelpers

  let(:tree) { File.realpath(Dir.mktmpdir("scratch-tree")) }
  let(:scratch) { described_class.new(globs: ["tmp", ".ruby-lsp", "rust/*/target"]) }

  after { FileUtils.rm_rf(tree) }

  it "clears the ignored directories the list names", :aggregate_failures do
    with_scratch
    expect(scratch.clear(tree)[:cleared]).to contain_exactly("tmp", "rust/kernel/target")
    expect(Dir.exist?(File.join(tree, "tmp"))).to be(false)
  end

  it "keeps a listed path that is not ignored" do
    repo(ignore: "")
    put("tmp/notes.txt")
    expect(scratch.clear(tree)).to eq(cleared: [], kept: ["tmp"])
  end

  it "keeps a listed path that holds a tracked file", :aggregate_failures do
    with_tracked_file
    expect(scratch.clear(tree)[:cleared]).to eq([])
    expect(File.exist?(File.join(tree, "tmp/keep.rb"))).to be(true)
  end

  it "never touches a file the list does not name" do
    repo
    put("loose.txt")
    scratch.clear(tree)
    expect(File.exist?(File.join(tree, "loose.txt"))).to be(true)
  end
end
