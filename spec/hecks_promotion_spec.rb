require "spec_helper"
require "fileutils"
require "tmpdir"

# Promotion through the launcher: `hecks promotion_run.promote` is a journaled run of PromotionRun.
# The adapter reports where the lane, the commit and each RequiredCheck stand; the givens of
# `Accept` decide; only an accepted run moves the lane, and without --confirm it is a rehearsal.
# The remote and GitHub are fakes over a scratch checkout, so nothing is fetched, pushed or asked.
RSpec.describe "promoting a lane" do
  let(:main_head) { "a" * 40 }
  let(:stable_head) { "b" * 40 }
  let(:root) { Dir.mktmpdir("hecks-promotion-spec") }

  # What `Git` is asked and what it is told to do, over refs held in a hash.
  let(:repo) do
    Class.new do
      attr_reader :moved, :tags

      def initialize(refs, ancestry, chain)
        @refs = refs
        @ancestry = ancestry
        @chain = chain
        @moved = []
        @tags = []
      end

      def remote_head(ref, chdir: nil) = @refs[ref.delete_prefix("refs/heads/")]
      def recent_commits(_newer, older: nil, limit: 25, chdir: nil) = @chain.first(limit)
      def ancestor?(older, newer, chdir: nil) = older == newer || @ancestry.include?([older, newer])
      def capture(*, chdir: nil) = nil

      def fast_forward(commit, branch, chdir: nil)
        @moved << [branch, commit]
      end

      def move_tag(tag, commit, chdir: nil)
        @tags << [tag, commit]
        :moved
      end
    end
  end

  # Where each check stands, by name.
  let(:checks) do
    Class.new do
      def initialize(states, by_commit)
        @states = states
        @by_commit = by_commit
      end

      def states(commit:, names:)
        standing = @states.merge(@by_commit.fetch(commit, {}))
        names.to_h { |name| [name, standing.fetch(name, :passed)] }
      end
    end
  end

  # `chain` is main's first-parent history above the lane, newest first; `by_commit` says where
  # checks stand against one particular commit, on top of `states` for every commit.
  def promote_with(refs:, ancestry: [], states: {}, chain: nil, by_commit: {})
    fake = repo.new(refs, ancestry, chain || [refs["main"]].compact)
    Hecks::Adapters::Codebase::Promotion.git = fake
    Hecks::Adapters::Codebase::Promotion.checks = checks.new(states, by_commit)
    fake
  end

  before do
    File.write(File.join(root, "hecks.gemspec"), "")
    FileUtils.mkdir_p(File.join(root, "lib"))
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
    Hecks::Adapters::Codebase::Tree.root = root
  end

  after do
    Hecks::Adapters::Codebase::Tree.root = nil
    Hecks::Adapters::Codebase::Promotion.git = nil
    Hecks::Adapters::Codebase::Promotion.checks = nil
    FileUtils.remove_entry(root)
  end

  def launch(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  def outcome(run) = launch("promotion_run.promotion_outcome", "run=#{run}").first

  # Main is ahead of stable, the usual state a promotion starts from.
  def ready(**more)
    promote_with(refs: { "main" => main_head, "stable" => stable_head }, ancestry: [[stable_head, main_head]], **more)
  end

  def promote(run, *args, lane: "stable", confirm: true)
    launch("promotion_run.promote", "run=#{run}", "lane=#{lane}", *args, *("--confirm" if confirm))
    outcome(run)
  end

  def completed = '"status": "completed"'

  def faulted = '"status": "faulted"'

  it "is a rehearsal without --confirm: it names the move and moves nothing", :aggregate_failures do
    fake = ready

    expect(promote("dry", confirm: false)).to include(completed, "rehearsal: would fast-forward stable bbbbbbb..aaaaaaa")
    expect([fake.moved, fake.tags]).to eq([[], []])
  end

  it "fast-forwards the lane and moves the tag it feeds when confirmed", :aggregate_failures do
    fake = ready

    expect(promote("real")).to include(completed, "fast-forwarded stable bbbbbbb..aaaaaaa, edge moved")
    expect([fake.moved, fake.tags]).to eq([[["stable", main_head]], [["edge", main_head]]])
  end

  it "does nothing, and does not fault, for a commit the lane already holds", :aggregate_failures do
    older = "d" * 40
    fake = ready(ancestry: [[older, main_head], [older, stable_head]])

    expect(promote("held", "commit=#{older}")).to include(completed, "stable already holds ddddddd")
    expect(fake.moved).to be_empty
  end

  it "brings the tag up to the lane when it already holds the commit: a half-done promotion is repaired", :aggregate_failures do
    older = "d" * 40
    fake = ready(ancestry: [[older, main_head], [older, stable_head]])

    expect(promote("repair", "commit=#{older}")).to include(completed, "stable already holds ddddddd, edge moved")
    expect([fake.moved, fake.tags]).to eq([[], [["edge", stable_head]]])
  end

  it "leaves the tag alone in a rehearsal, even when the lane holds the commit" do
    older = "d" * 40
    fake = ready(ancestry: [[older, main_head], [older, stable_head]])

    promote("held-dry", "commit=#{older}", confirm: false)
    expect(fake.tags).to be_empty
  end

  # Commits arrive faster than CI certifies them: stable < oldest < middle < newest, all on main.
  describe "when commits arrive faster than CI certifies them" do
    def newest = "e" * 40

    def middle = "d" * 40

    def oldest = "c" * 40

    def stacked(lane: stable_head, **more)
      order = [stable_head, oldest, middle, newest]
      promote_with(refs: { "main" => newest, "stable" => lane }, ancestry: order.combination(2).to_a,
                   chain: [newest, middle, oldest], **more)
    end

    it "moves the lane onto the newest certified commit when the head is still running", :aggregate_failures do
      fake = stacked(by_commit: { newest => { "rspec" => :pending }, middle => { "rspec_rust_io" => :pending } })

      expect(promote("stack")).to include(completed, "fast-forwarded stable bbbbbbb..ccccccc")
      expect(fake.moved).to eq([["stable", oldest]])
    end

    it "does not strand a certified commit behind a red one", :aggregate_failures do
      fake = stacked(by_commit: { newest => { "rspec" => :failed } })

      expect(promote("red-head")).to include(completed, "fast-forwarded stable bbbbbbb..ddddddd")
      expect(fake.moved).to eq([["stable", middle]])
    end

    it "takes the newest of several certified commits, so a superseded one is never promoted", :aggregate_failures do
      fake = stacked

      expect(promote("newest")).to include(completed, "bbbbbbb..eeeeeee")
      expect(fake.moved).to eq([["stable", newest]])
    end

    it "names the head's red check when no commit is certified, and moves nothing", :aggregate_failures do
      fake = stacked(states: { "rspec" => :failed })

      expect(promote("none")).to include(faulted, "failed: rspec")
      expect(fake.moved).to be_empty
    end

    it "promotes only the exact commit it is told to: a named red commit is never swapped for another", :aggregate_failures do
      fake = stacked(by_commit: { middle => { "rspec" => :failed } })

      expect(promote("exact", "commit=#{middle}")).to include(faulted, "failed: rspec")
      expect(fake.moved).to be_empty
    end

    it "is a no-op, not a fault, when the lane is already past the commit that started the run", :aggregate_failures do
      fake = stacked(lane: newest)

      expect(promote("late", "commit=#{oldest}")).to include(completed, "stable already holds ccccccc")
      expect(fake.moved).to be_empty
    end
  end

  it "makes the lane when it does not yet exist", :aggregate_failures do
    fake = promote_with(refs: { "main" => main_head })

    expect(promote("first")).to include(completed, "fast-forwarded stable none..aaaaaaa")
    expect(fake.moved).to eq([["stable", main_head]])
  end

  it "refuses while a required check is red, naming it, and moves nothing", :aggregate_failures do
    fake = ready(states: { "rspec_rust_io" => :failed })

    expect(promote("red")).to include(faulted, "failed: rspec_rust_io")
    expect(fake.moved).to be_empty
  end

  it "refuses while a required check has not finished, and says it is waiting", :aggregate_failures do
    fake = ready(states: { "rspec" => :pending, "checks" => :missing })

    expect(promote("wait")).to include(faulted, "waiting on: rspec, checks")
    expect(fake.moved).to be_empty
  end

  it "refuses a commit that does not contain the lane's head: a lane only moves forward", :aggregate_failures do
    other = "c" * 40
    fake = ready(ancestry: [[other, main_head]])

    expect(promote("back", "commit=#{other}")).to include(faulted, "not a fast-forward")
    expect(fake.moved).to be_empty
  end

  it "refuses a lane that no Lane row follows another lane", :aggregate_failures do
    fake = promote_with(refs: { "main" => main_head })

    expect(promote("main", lane: "main")).to include(faulted, "is not a Lane row that follows another lane")
    expect(fake.moved).to be_empty
  end

  it "refuses outside a hecks checkout, and asks neither the remote nor GitHub", :aggregate_failures do
    fake = promote_with(refs: { "main" => main_head })
    FileUtils.rm_f(File.join(root, "hecks.gemspec"))

    expect(promote("away")).to include(faulted, "needs a hecks checkout")
    expect(fake.moved).to be_empty
  end
end
