require "spec_helper"
require "yaml"

# ci.yml's required-check wrappers (`rspec`, `checks`, the Postgres and Rust
# lineages) each mirror one reusable-workflow call's `.result`. Since PR
# #694 a wrapper RUNS ONLY TO FAIL: a wrapper skipped by its own `if:` needs
# no runner and reports as passing. That made a skipped `_impl` pass
# unconditionally — so a call that skipped where it should have run (on the
# merge queue, say) went green having run nothing.
#
# Each wrapper's `if:` now also runs (and fails) when its `_impl` skipped
# but its own skip condition did NOT hold. This pins that shape: no wrapper
# lets `skipped` through without a condition, and the condition is an
# expression, never a constant.
#
# A wrapper whose call has NO event it legitimately skips on writes the
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

  # The light PR set (PR #666) is gone: every job runs on `pull_request`
  # again. Nothing may gate on the label that used to put a PR back on the
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
end
