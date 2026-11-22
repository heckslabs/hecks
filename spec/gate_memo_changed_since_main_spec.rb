require "spec_helper"
require "fileutils"
require "open3"
require "hecks/tools/gate_memo/ruby_files"

# The quick stage's rubocop lints what a landing changed since main, whatever the memo says: a
# memo whose baseline already holds the branch's files cannot let a style offense land.
RSpec.describe "The quick stage's rubocop on a landing's changed files" do
  let(:root) { Dir.mktmpdir("gate-memo-since-main") }
  let(:ruby) { Hecks::Tools::GateMemo::RubyFiles }

  after { FileUtils.rm_rf(root) }

  def git(*args) = Open3.capture2e("git", "-C", root, *args).first

  def write(rel, text)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def commit(message)
    git("add", "-A")
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
  end

  def memo_entry = { "inputs" => ruby.config(root), "files" => ruby.hashes(root) }

  def plan = ruby.plan(root, memo_entry, ruby.hashes(root))

  before do
    git("init", "-q", "-b", "main")
    write("lib/a.rb", "A = 1\n")
    commit("main")
  end

  context "with a branch that changed a Ruby file the memo already holds" do
    before do
      git("checkout", "-q", "-b", "work")
      write("lib/b.rb", "B = 1\n")
      commit("work")
    end

    it "lints the changed file though the memo says every file is unchanged" do
      expect(plan).to include(:incremental, %w[lib/b.rb])
    end
  end

  context "with a branch that changed no Ruby file" do
    before do
      git("checkout", "-q", "-b", "work")
      write("notes.md", "notes\n")
      commit("work")
    end

    it "skips rubocop when the memo says every file is unchanged" do
      expect(plan.first).to eq(:skip)
    end
  end

  it "skips rubocop on main itself, where nothing changed since main" do
    expect(plan.first).to eq(:skip)
  end

  it "skips rubocop in a checkout with no main to compare with" do
    git("branch", "-q", "-m", "trunk")
    expect(plan.first).to eq(:skip)
  end
end
