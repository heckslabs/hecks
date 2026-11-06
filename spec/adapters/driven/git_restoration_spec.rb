# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/git_restoration"

# Putting back the changed files that already match origin/main, and only those. The repository is
# a real one in a temporary directory; its `origin/main` is a commit the files are compared to.
RSpec.describe Hecks::Adapters::GitRestoration do
  let(:dir) { File.realpath(Dir.mktmpdir("restoration")) }
  let(:adapter) { described_class.new }

  after { FileUtils.rm_rf(dir) }

  def git(*args) = system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", *args, out: File::NULL, err: File::NULL)

  def write(name, text) = File.write(File.join(dir, name), text)

  def read_file(name) = File.read(File.join(dir, name))

  # Two files at "one"; origin/main holds `golden` at "two"; the working tree changes both files.
  def repository
    commit_both_files
    write("golden", "two")
    git("commit", "-q", "-am", "two")
    git("update-ref", "refs/remotes/origin/main", "HEAD")
    git("reset", "-q", "--hard", "HEAD~1")
    write("golden", "two")
    write("other", "mine")
  end

  def commit_both_files
    git("init", "-q", "-b", "work")
    write("golden", "one")
    write("other", "one")
    git("add", ".")
    git("commit", "-q", "-m", "one")
  end

  def restore = adapter.restore(checkout: { value: dir })

  it "restores a changed file that matches origin/main, and keeps one that differs", :aggregate_failures do
    repository
    expect(restore[:report][:value]).to eq("restored 1 file(s) that match origin/main; kept 1 that differ: other")
    expect([read_file("golden"), read_file("other")]).to eq(%w[one mine])
  end

  it "declines when no changed file matches origin/main" do
    repository
    write("golden", "mine too")
    failure = Hecks::Adapters::ConsoleCapture::Failure
    expect { restore }.to raise_error(failure, %r{no changed file matches origin/main; kept golden, other})
  end

  it "declines when nothing is changed" do
    repository
    git("checkout", "-q", "--", ".")
    expect { restore }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no tracked file is changed/)
  end
end
