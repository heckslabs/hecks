# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/landing/own_stores"
require "tmpdir"
require "open3"

# A landed worktree that holds only the stores it wrote for itself is retired, stores and all;
# any other ignored file still keeps it, and a worktree whose branch has not landed keeps its
# stores. Every example builds its own throwaway repository; the real one is never read.
RSpec.describe Hecks::Adapters::Landing::OwnStores do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-own-stores")) }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:stores) { %w[data/tickets.heki data/tickets.heki.journal pipeline.db pipeline.db-wal data/eras/x/0001] }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def write(*names)
    names.each do |name|
      FileUtils.mkdir_p(File.dirname(File.join(tree, name)))
      File.write(File.join(tree, name), "x")
    end
  end

  # A repository whose linked worktree on `work/a` ignores stores and `.env`, holds the files
  # named, and is landed on `main` unless `landed:` is false.
  def build(*names, landed: true)
    init_repo
    git("worktree", "add", "-b", "work/a", tree)
    write("a.rb")
    git("add", ".", chdir: tree)
    git("commit", "-m", "a", chdir: tree)
    git("merge", "work/a") if landed
    write(*names)
  end

  def init_repo
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    File.write(File.join(repo, ".gitignore"), "*.heki\n*.heki.journal\n*.db\n*.db-wal\n**/data/eras/\n.env\n")
    git("add", ".")
    git("commit", "-m", "ignore")
  end

  def retire = Hecks::Adapters::GitLanding.new.remove(checkout: tree, branch: "work/a", onto: "main")

  it "retires a landed worktree whose only ignored files are its own stores", :aggregate_failures do
    build(*stores)
    expect(retire.dig(:report, :value)).to include("and deleted work/a")
    expect(File.exist?(tree)).to be(false)
  end

  it "keeps a landed worktree that holds an ignored file beside its stores, and names it" do
    build(*stores, ".env")
    expect { retire }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /\.env/)
  end

  it "names no store among the files that keep it" do
    build(*stores, ".env")
    expect { retire }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /\A(?!.*\.heki)(?!.*\.db).*\z/m)
  end

  it "keeps a worktree whose branch has not landed, stores and all", :aggregate_failures do
    build(*stores, landed: false)
    expect { retire }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
    expect(stores.map { |name| File.exist?(File.join(tree, name)) }).to all(be(true))
  end

  describe ".store?" do
    it "takes an ignored Heki journal at any depth for a store" do
      expect(described_class.store?("!! lib/x/data/tickets.heki.journal")).to be(true)
    end

    it "does not take an untracked store-named file for one" do
      expect(described_class.store?("?? pipeline.db")).to be(false)
    end

    it "does not take an ignored file of another name for one" do
      expect(described_class.store?("!! .env")).to be(false)
    end
  end
end
