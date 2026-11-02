require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "sqlite3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/push_recorder"

# The `PushRecords` port's adapter, end to end: the train pushes a clone to a local bare repository,
# then the recorder runs this checkout's launcher in the clone, whose local overlay keeps
# `PushOutcome` in a scratch SQLite file, as the primary checkout's overlay keeps it in
# `agent_run.db`. The journal of that file then holds the recorded push.
RSpec.describe Hecks::Adapters::PushRecorder, :io do
  let(:scratch) { File.realpath(Dir.mktmpdir("hecks-push-recorder")) }
  let(:work) { File.join(scratch, "work") }
  let(:database) { File.join(scratch, "agent_run.db") }
  let(:launcher) { File.join(InMemoryDomain::ROOT, "exe", "hecks") }

  def git(*args, dir: work)
    out, err, status = Open3.capture3("git", "-c", "user.name=A", "-c", "user.email=a@example.test", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  # The clone's own overlay, beside its working files: `PushOutcome` in the scratch database.
  OVERLAY = <<~RUBY.freeze
    Hecks.hecksagon "Hecks" do
      persisted_by "Memory"
      Hecks::PushOutcome.persisted_by("SqlitePersistence")
    end
  RUBY

  def overlay
    File.write(File.join(work, "hecks.local.hecksagon"), OVERLAY)
    File.write(File.join(work, "hecks.local.world"), <<~RUBY)
      Hecks.world "Hecks" do
        persisted_by("SqlitePersistence") { database #{database.inspect} }
      end
    RUBY
  end

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
    overlay
  end

  after { FileUtils.remove_entry(scratch) }

  def still_mint = instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape did not move")

  # Two commits pushed by the train, then the pushed run recorded as the policy asks for it.
  def push_and_record
    commit("second")
    commit("third")
    answer = Hecks::Adapters::GitTrain.new(mint: still_mint).carry(checkout: { value: work })
    held = answer.merge(run: { value: "push-1" }, status: "pushed", branch: { value: "main" })
    described_class.new(settings: { launcher: launcher }).record_outcome(**held)
    answer
  end

  def recorded
    SQLite3::Database.new(database).execute("SELECT name, payload FROM events WHERE name = 'PushRecorded'")
                     .map { |_name, payload| JSON.parse(payload) }
  end

  it "records the push in the checkout's own journal, with its commit, branch, count and report", :aggregate_failures do
    pushed = push_and_record.dig(:pushed, :value)

    expect(recorded.first).to include("pushed" => { "value" => pushed }, "branch" => { "value" => "main" },
                                      "commits" => { "value" => 2 }, "checkout" => { "value" => "#{work}/" })
    expect(recorded.first.dig("report", "value")).to start_with("pushing 2 commits")
  end

  it "refuses a boarding that names no checkout, recording nothing" do
    expect { described_class.new.record_outcome(run: { value: "push-2" }, status: "faulted") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /names no checkout/)
  end
end
