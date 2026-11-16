require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# A boarding whose `gh pr create` meets a spent rate limit waits and asks again, and names the
# step it could not finish; the pushed branch stays for a re-board. `gh` is a fake and nothing waits.
RSpec.describe "the push train under a GitHub rate limit", :io do
  LIMIT_SAID = "GraphQL: API rate limit already exceeded for user ID 1".freeze
  LIMIT_IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
                     "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }.freeze

  let(:scratch) { Dir.mktmpdir("hecks-rate-limit") }
  let(:work) { File.join(scratch, "work") }
  let(:creates) { [] }
  let(:waits) { [] }

  def git(*args, dir: work)
    out, err, status = Open3.capture3(LIMIT_IDENTITY, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  # `gh pr create` answers each scripted reply in turn, the last repeating; everything else succeeds.
  def github(replies)
    lambda do |argv, **|
      next [false, "no pull request found"] if argv[1..2] == %w[pr view]
      next [true, ""] unless argv[1..2] == %w[pr create]

      creates << argv
      replies[[creates.size - 1, replies.size - 1].min]
    end
  end

  def carry(replies)
    mint = instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape did not move")
    train = Hecks::Adapters::GitTrain.new(mint: mint, runner: github(replies), pause: ->(seconds) { waits << seconds })
    train.carry(checkout: { value: work })
  end

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    File.write(File.join(work, "first"), "first")
    git("add", "first")
    git("commit", "-q", "-m", "first")
    git("push", "-q", "origin", "main")
    File.write(File.join(work, "second"), "second")
    git("add", "second")
    git("commit", "-q", "-m", "second")
  end

  after { FileUtils.remove_entry(scratch) }

  it "opens the pull request once the limit lifts", :aggregate_failures do
    answer = carry([[false, LIMIT_SAID], [true, "https://github.test/o/r/pull/9\n"]])

    expect(answer).to include(outcome: { value: "queued" })
    expect(creates.size).to eq(2)
    expect(waits).to eq([20])
  end

  it "names the rate limit and the branch left pushed when it never lifts", :aggregate_failures do
    expect { carry([[false, LIMIT_SAID]]) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{rate limit; train/main-\h+ stays pushed, board again})
    expect(creates.size).to eq(Hecks::Adapters::GitTrain::RateLimitRetry::ATTEMPTS)
  end

  it "does not retry a refusal that is not the rate limit", :aggregate_failures do
    expect { carry([[false, "boom"]]) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /boom/)
    expect(waits).to be_empty
  end
end
