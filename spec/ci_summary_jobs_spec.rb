require "spec_helper"
require "yaml"

# ci.yml's required-check wrappers (`rspec`, `checks`, the Postgres and Rust
# lineages) each mirror one reusable-workflow call's `.result`. Since PR
# #694 a wrapper runs only to fail: a wrapper skipped by its own `if:` needs
# no runner and reports as passing. That made a skipped `_impl` pass
# unconditionally — so a call that skipped where it should have run (on the
# merge queue, say) went green having run nothing.
#
# Each wrapper's `if:` now also runs (and fails) when its `_impl` skipped
# but its own skip condition did not hold. This pins that shape: no wrapper
# lets `skipped` through without a condition, and the condition is an
# expression, never a constant.
#
# A wrapper whose call has no event it legitimately skips on writes the
# other legal shape instead — `always() && <impl>.result != 'success'`,
# tolerating no skip at all — and then must not claim a skip is expected.
# `rspec_postgres_io_parallel` is the only one: since the light PR set was
# removed (2026-09-18) every other call skips exactly on the cache-warming
# `push`, and that one skips nowhere. Nothing here may name a label: the
# `full-ci` label went with the light PR set.
RSpec.describe ".github/workflows/ci.yml required-check wrappers" do
  CI_YML = File.join(InMemoryDomain::ROOT, ".github/workflows/ci.yml")

  def self.jobs = YAML.load_file(CI_YML).fetch("jobs")

  def self.wrappers
    jobs.select { |_, job| job["needs"].to_s.end_with?("_impl") && job["if"].to_s.start_with?("always() &&") }
  end

  it "finds the eight required-check wrappers" do
    expect(self.class.wrappers.keys).to contain_exactly(
      "rspec", "checks", "rspec_postgres_io", "rspec_postgres_io_parallel",
      "rspec_rust_io", "rspec_rust_parser", "rspec_rust_codegen", "rspec_rust_host"
    )
  end

  # The skip condition inside a wrapper's `if:`, or nil when the `if:` does
  # not have the "success, or skipped where expected" shape at all.
  def skip_condition(job)
    impl = Regexp.escape(job.fetch("needs"))
    shape = /\Aalways\(\) && !\(needs\.#{impl}\.result == 'success' \|\| \(needs\.#{impl}\.result == 'skipped' && \((.+)\)\)\)\z/
    job.fetch("if")[shape, 1]
  end

  wrappers.each do |name, job|
    it "#{name} lets #{job.fetch('needs')}'s skip through only when its own skip condition holds" do
      impl = job.fetch("needs")
      condition = skip_condition(job)
      step = job.fetch("steps").first

      if condition.nil?
        expect(job.fetch("if")).to eq("always() && needs.#{impl}.result != 'success'"),
                                   "#{name}'s if: must be either `always() && !(needs.#{impl}.result == 'success' || " \
                                   "(needs.#{impl}.result == 'skipped' && (<skip condition>)))` or, when nothing about " \
                                   "#{impl} ever legitimately skips, `always() && needs.#{impl}.result != 'success'`; " \
                                   "got #{job['if'].inspect}"
        expect(step.dig("env", "SKIP_EXPECTED")).to be_nil,
                                                    "#{name} tolerates no skip at all, so it must not claim one is expected"
      else
        expect(condition).to include("github.event_name"), "#{name}: the skip condition must be an expression, not a constant"
        expect(step.dig("env", "SKIP_EXPECTED")).to eq("${{ #{condition} }}")
      end

      expect(step.fetch("run")).to include("exit 1")
      expect(step.fetch("run")).not_to include("exit 0"), "#{name} runs only to fail — its step must never pass"
    end
  end

  # The light PR set is gone: every job runs on `pull_request`
  # again. Nothing may gate on the retired label that once put a PR back on the
  # full set, or the gap it opened — a job that never ran on the PR failing
  # in the merge queue and ejecting the batch — comes straight back.
  it "gates no job on the retired full-ci label" do
    [CI_YML, File.join(InMemoryDomain::ROOT, ".github/workflows/ci-checks.yml")].each do |path|
      YAML.load_file(path).fetch("jobs").each do |name, job|
        expect(job["if"].to_s).not_to include("full-ci"),
                                      "#{File.basename(path)}'s #{name} still gates on the retired full-ci label: #{job['if']}"
      end
    end
  end

  # `merge_group.base_sha` is the previous queue entry, not the target
  # branch, and the queue merges a whole group on its last entry's run. A
  # path gate that diffs against it lets a gate-skipped PR carry a red one
  # in ahead of it — #729 behind #730, 2026-09-18.
  it "diffs no merge group against the previous queue entry" do
    Dir[File.join(InMemoryDomain::ROOT, ".github/{workflows,actions}/**/*.yml")].each do |path|
      YAML.load_file(path).fetch("jobs", {}).each do |name, job|
        job.fetch("steps", []).each do |step|
          script = step["run"].to_s.gsub(/^\s*#.*$/, "")
          expect(script).not_to include("merge_group.base_sha"),
                                "#{File.basename(path)}'s #{name} reads merge_group.base_sha — diff against " \
                                "`git merge-base origin/<base_ref> <sha>` instead"
        end
      end
    end
  end

  # A push to main tests nothing — the merge queue already did — so all a
  # push run may spend a runner on is the Postgres detector's checkout and
  # diff. Eight Postgres legs ran there for a cache nobody had read since
  # 2026-09-14. A job skips on push by saying so, or by needing one that does.
  it "spends no runner on a push to main beyond the Postgres detector" do
    Dir[File.join(InMemoryDomain::ROOT, ".github/workflows/ci*.yml")].each do |path|
      jobs = YAML.load_file(path).fetch("jobs")
      skips_on_push = ->(job) { job["if"].to_s.include?("github.event_name != 'push'") }
      jobs.each do |name, job|
        next if job.key?("uses") || name == "postgres_io_relevant_changed" || self.class.wrappers.key?(name)

        upstream = Array(job["needs"]).map { |needed| jobs.fetch(needed) }
        skipped = skips_on_push.call(job) || upstream.any?(&skips_on_push)
        expect(skipped).to be(true), "#{File.basename(path)}'s #{name} would take a runner on a push to main"
      end
    end
  end

  # A job with no timeout falls back to GitHub's 360 minutes, and a hung
  # job holds one of the account's 20 concurrent runner slots that whole time.
  it "gives every job that takes a runner a timeout" do
    Dir[File.join(InMemoryDomain::ROOT, ".github/workflows/*.yml")].each do |path|
      YAML.load_file(path).fetch("jobs").each do |name, job|
        next if job.key?("uses")

        expect(job["timeout-minutes"]).to be_a(Integer).and(be <= 60),
                                          "#{File.basename(path)}'s #{name} needs a timeout-minutes of at most 60"
      end
    end
  end
end
