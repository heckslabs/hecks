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

      def initialize(refs, ancestry)
        @refs = refs
        @ancestry = ancestry
        @moved = []
        @tags = []
      end

      def remote_head(ref, chdir: nil) = @refs[ref.delete_prefix("refs/heads/")]
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
      def initialize(states) = @states = states
      def states(commit:, names:) = names.to_h { |name| [name, @states.fetch(name, :passed)] }
    end
  end

  def promote_with(refs:, ancestry: [], states: {})
    fake = repo.new(refs, ancestry)
    Hecks::Adapters::Codebase::Promotion.git = fake
    Hecks::Adapters::Codebase::Promotion.checks = checks.new(states)
    fake
  end

  before do
    File.write(File.join(root, "hecks.gemspec"), "")
    FileUtils.mkdir_p(File.join(root, "lib"))
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    Hecks::Adapters::Codebase::Tree.root = root
  end

  after do
    Hecks::Adapters::Codebase::Tree.root = nil
    Hecks::Adapters::Codebase::Promotion.git = nil
    Hecks::Adapters::Codebase::Promotion.checks = nil
    FileUtils.remove_entry(root)
  end

  def launch(*argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  def outcome(run) = launch("promotion_run.promotion_outcome", "run=#{run}").first

  it "is a rehearsal without --confirm: it names the move and moves nothing" do
    fake = promote_with(refs: { "main" => main_head, "stable" => stable_head }, ancestry: [[stable_head, main_head]])

    _, status = launch("promotion_run.promote", "run=dry", "lane=stable")
    out = outcome("dry")

    expect(status).to eq(0)
    expect(out).to include('"status": "completed"', "rehearsal: would fast-forward stable bbbbbbb..aaaaaaa")
    expect(fake.moved).to be_empty
    expect(fake.tags).to be_empty
  end

  it "fast-forwards the lane and moves the tag it feeds when confirmed" do
    fake = promote_with(refs: { "main" => main_head, "stable" => stable_head }, ancestry: [[stable_head, main_head]])

    launch("promotion_run.promote", "run=real", "lane=stable", "--confirm")

    expect(outcome("real")).to include('"status": "completed"', "fast-forwarded stable bbbbbbb..aaaaaaa, edge moved")
    expect(fake.moved).to eq([["stable", main_head]])
    expect(fake.tags).to eq([["edge", main_head]])
  end

  it "does nothing, and does not fault, for a commit the lane already holds" do
    older = "d" * 40
    fake = promote_with(refs:     { "main" => main_head, "stable" => stable_head },
                        ancestry: [[older, main_head], [older, stable_head]])

    launch("promotion_run.promote", "run=held", "lane=stable", "commit=#{older}", "--confirm")

    expect(outcome("held")).to include('"status": "completed"', "stable already holds ddddddd")
    expect(fake.moved).to be_empty
    expect(fake.tags).to be_empty
  end

  it "makes the lane when it does not yet exist" do
    fake = promote_with(refs: { "main" => main_head })

    launch("promotion_run.promote", "run=first", "lane=stable", "--confirm")

    expect(outcome("first")).to include('"status": "completed"', "fast-forwarded stable none..aaaaaaa")
    expect(fake.moved).to eq([["stable", main_head]])
  end

  it "refuses while a required check is red, naming it, and moves nothing" do
    fake = promote_with(refs: { "main" => main_head, "stable" => stable_head },
                        ancestry: [[stable_head, main_head]], states: { "rspec_rust_io" => :failed })

    launch("promotion_run.promote", "run=red", "lane=stable", "--confirm")

    expect(outcome("red")).to include('"status": "faulted"', "failed: rspec_rust_io")
    expect(fake.moved).to be_empty
  end

  it "refuses while a required check has not finished, and says it is waiting" do
    fake = promote_with(refs: { "main" => main_head, "stable" => stable_head },
                        ancestry: [[stable_head, main_head]], states: { "rspec" => :pending, "checks" => :missing })

    launch("promotion_run.promote", "run=wait", "lane=stable", "--confirm")

    expect(outcome("wait")).to include('"status": "faulted"', "waiting on: rspec, checks")
    expect(fake.moved).to be_empty
  end

  it "refuses a commit that does not contain the lane's head: a lane only moves forward" do
    other = "c" * 40
    fake = promote_with(refs:     { "main" => main_head, "stable" => stable_head },
                        ancestry: [[other, main_head]])

    launch("promotion_run.promote", "run=back", "lane=stable", "commit=#{other}", "--confirm")

    expect(outcome("back")).to include('"status": "faulted"', "not a fast-forward")
    expect(fake.moved).to be_empty
  end

  it "refuses a lane that no Lane row follows another lane" do
    fake = promote_with(refs: { "main" => main_head })

    launch("promotion_run.promote", "run=main", "lane=main", "--confirm")

    expect(outcome("main")).to include('"status": "faulted"', "is not a Lane row that follows another lane")
    expect(fake.moved).to be_empty
  end

  it "refuses outside a hecks checkout, and asks neither the remote nor GitHub" do
    fake = promote_with(refs: { "main" => main_head })
    FileUtils.rm_f(File.join(root, "hecks.gemspec"))

    launch("promotion_run.promote", "run=away", "lane=stable", "--confirm")

    expect(outcome("away")).to include('"status": "faulted"', "needs a hecks checkout")
    expect(fake.moved).to be_empty
  end
end
