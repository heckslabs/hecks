require "spec_helper"
require "hecks/hecks/adapters/main_integration"
require "open3"
require "securerandom"

# After a train pull request merged on origin, a tip made on the old base of local main boards
# without a hand: the integration merges origin/main into main before it opens the run for the
# tip, and a merge that conflicts parks the run in needs_human naming the files. The repository
# is a throwaway one with a bare origin; the registry and the dispatcher are stand-ins.
RSpec.describe Hecks::Adapters::MainIntegration::Adoption do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-level-main")) }
  let(:repo) { File.join(dir, "repo") }
  let(:other) { File.join(dir, "other") }
  let(:registry) { Struct.new(:saga_instances).new({ "MainIntegration" => { "old" => old_run } }) }
  let(:dispatcher) { instance_double(Hecks::Runtime::Dispatcher, dispatch_flat: nil) }

  def old_run = { state: "green", memory: { checkout: repo } }

  before do
    open_repositories
    allow(Hecks::Runtime::Dispatcher).to receive(:new).and_return(dispatcher)
    allow(Hecks::Adapters::MainIntegration::TrainChecks).to receive(:new)
      .and_return(instance_double(Hecks::Adapters::MainIntegration::TrainChecks, blocking: nil))
    Hecks::Adapters::MainIntegration::BoardedCheck.runner = ->(_argv, chdir:) { [true, chdir && "[]"] }
  end

  after do
    Hecks::Adapters::MainIntegration::BoardedCheck.runner = nil
    FileUtils.remove_entry(dir)
  end

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(where, file, content = SecureRandom.hex)
    File.write(File.join(where, file), content)
    git("add", ".", chdir: where)
    git("commit", "-q", "-m", file, chdir: where)
  end

  def open_repositories
    git("init", "--bare", "-b", "main", File.join(dir, "origin.git"), chdir: dir)
    [repo, other].each { |where| git("clone", "-q", File.join(dir, "origin.git"), where, chdir: dir) }
    commit(repo, "README", "one")
    git("push", "-q", "origin", "main")
    git("pull", "-q", "origin", "main", chdir: other)
  end

  # The train merged on origin; a tip was made on local main's old base.
  def merge_train_then_tip(file: "train.txt", tip_file: "tip.txt", tip_content: "tip")
    commit(other, file, "train")
    git("push", "-q", "origin", "main", chdir: other)
    commit(repo, tip_file, tip_content)
  end

  it "merges origin/main into main before it opens the run for the tip", :aggregate_failures do
    merge_train_then_tip
    described_class.new(registry).open_run
    expect(git("merge-base", "--is-ancestor", "origin/main", "main")).to eq("")
    expect(git("show", "main:tip.txt")).to eq("tip")
  end

  it "opens the run for the merged tip" do
    merge_train_then_tip
    described_class.new(registry).open_run
    expect(dispatcher).to have_received(:dispatch_flat)
      .with("Delivery::Landing.Adopt", hash_including(landed: git("rev-parse", "main")))
  end

  def conflict_with_origin
    commit(repo, "same.txt", "mine")
    commit(other, "same.txt", "theirs")
    git("push", "-q", "origin", "main", chdir: other)
  end

  it "leaves main where it was when the merge conflicts" do
    conflict_with_origin
    expect { described_class.new(registry).open_run }.not_to(change { git("rev-parse", "main") })
  end

  it "parks the run in needs_human naming the files when the merge conflicts" do
    conflict_with_origin
    described_class.new(registry).open_run
    expect(dispatcher).to have_received(:dispatch_flat)
      .with("Hecks::Integration.Strand", hash_including(refusal: a_string_including("same.txt")))
  end
end
