require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "support/registry_double"
require "hecks/tickets/bluebook/adapters/done_off_main"

# The DoneOffMain port's adapter against a throwaway repository and a stubbed Work repository: a
# done work item's branch is listed only while main lacks its tip.
RSpec.describe Hecks::Adapters::DoneOffMain do
  include RegistryDouble

  let(:dir) { File.realpath(Dir.mktmpdir("hecks-done-off-main")) }

  before do
    git("init", "-b", "main")
    commit("README")
  end

  after { FileUtils.remove_entry(dir) }

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: dir)
    raise out unless status.success?

    out
  end

  def commit(file)
    File.write(File.join(dir, file), "x")
    git("add", ".")
    git("commit", "-m", file)
  end

  def branch_with(name, merged:)
    git("checkout", "-b", name)
    commit("#{name.tr("/", "-")}.rb")
    git("checkout", "main")
    git("merge", "--no-ff", "-m", "merge #{name}", name) if merged
  end

  def item(key, status) = { work: key, status: status }

  def sweep(*items, root: dir)
    registry = registry_double
    allow(registry).to receive(:repository).and_return(Struct.new(:all).new(items))
    allow(Hecks::Adapters::StartedWork).to receive(:work_aggregate).and_return(Object.new)
    described_class.new(registry: registry, settings: { root: root }).done_off_main
  end

  it "lists the branch of a done item whose tip main lacks", :aggregate_failures do
    branch_with("lost", merged: false)

    expect(sweep(item("lost", "done"))[:text]).to match(/\Alost lost \h{9}\n\z/)
  end

  it "leaves out a done item whose branch landed" do
    branch_with("landed", merged: true)

    expect(sweep(item("landed", "done"))).to eq(text: "")
  end

  it "leaves out an item that is not done" do
    branch_with("open", merged: false)

    expect(sweep(item("open", "started"))).to eq(text: "")
  end

  it "leaves out a done item with no branch" do
    expect(sweep(item("nobranch", "done"))).to eq(text: "")
  end

  it "names the item by the branch without a leading qa/" do
    branch_with("qa/lost", merged: false)

    expect(sweep(item("lost", "done"))[:text]).to start_with("lost qa/lost ")
  end

  it "refuses by name when main does not exist" do
    git("checkout", "-b", "other")
    git("branch", "-D", "main")

    expect { sweep(item("other", "done")) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /merge-base/)
  end

  it "refuses by name when the directory is not a repository" do
    expect { sweep(root: Dir.tmpdir) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /for-each-ref/)
  end
end
