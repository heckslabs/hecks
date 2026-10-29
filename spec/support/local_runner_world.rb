require "fileutils"
require "open3"
require "tmpdir"
require "hecks/ci_speed/adapters/local_runner"

# What the specs of the CiSpeed `LocalRunner` share: a tiny definition whose steps ask the launcher
# for usage, so nothing is regenerated, and two commits of this repository: its newest and one on
# top of it with the same tree, made in the spec's own clone, because CI checks out one commit and
# has no `HEAD~1` to name. The repository the adapter asks is a shared clone made for the spec, so
# what the adapter does to "the caller's checkout" can be read off exactly while other work goes on
# in the working tree the spec runs from.
RSpec.shared_context "with a local runner over a shared clone" do
  let(:catalog_class) { described_class::Catalog }

  before do
    git(Dir.pwd, "clone", "--shared", "--no-checkout", "--quiet", Dir.pwd, caller_checkout)
    commit_the_same_tree_again(caller_checkout)
  end

  after { FileUtils.remove_entry(scratch) }

  def scratch = @scratch ||= Dir.mktmpdir("ci-speed-runner-spec-")

  def caller_checkout = File.join(scratch, "caller")

  def git(directory, *words)
    out, status = Open3.capture2e("git", "-C", directory, *words)
    raise "git #{words.join(" ")} failed: #{out}" unless status.success?

    out
  end

  # Moves `HEAD` to a new commit with its tree, so `HEAD~1` names a commit however deep the clone
  # is. A commit made from the index would be empty: the clone is made without a checkout.
  def commit_the_same_tree_again(directory)
    author = ["-c", "user.name=ci speed spec", "-c", "user.email=ci-speed-spec@example.test"]
    made = git(directory, *author, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "the same tree again").strip
    git(directory, "update-ref", "HEAD", made)
  end

  def step(name, verb, needs: "none", arguments: "--help")
    catalog_class::Step.new(name: name, verb: verb, arguments: arguments, needs: needs)
  end

  def definition(*steps, needs_generated_tree: "no")
    catalog_class.new([catalog_class::Definition.new(name: "tiny", measures: "the launcher's usage",
                                                     cache_state: "miss", steps: steps,
                                                     needs_generated_tree: needs_generated_tree)])
  end

  def runner_for(catalog)
    described_class.new(catalog: catalog, root: caller_checkout, scratch: File.join(scratch, "runs"))
  end

  def usage_runner = runner_for(definition(step("usage", "Checkout.status")))

  def experiment(**changes)
    { measures: { value: "tiny" }, cache_state: { value: "miss" }, base_ref: { value: "HEAD~1" },
      candidate_ref: { value: "HEAD" }, repeats: { value: 2 } }.merge(changes)
  end

  def standing(directory)
    { head: git(directory, "rev-parse", "HEAD"), status: git(directory, "status", "--porcelain"),
      worktrees: git(directory, "worktree", "list", "--porcelain") }
  end

  def checkouts_of(runner) = runner.trail.map { |taken| taken[:checkout] }.uniq

  def steps_this_machine_cannot_run
    [step("load_database", "Checkout.status", needs: "postgres"), step("no_such_verb", "NoSuchAggregate.nothing!")]
  end

  def unmeasured_of(*steps)
    runner_for(definition(*steps)).measure(**experiment).fetch(:unmeasured).fetch(:value)
  end
end
