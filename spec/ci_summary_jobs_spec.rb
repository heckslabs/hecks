require "spec_helper"
require "yaml"

# ci.yml's required-check wrappers mirror one reusable-workflow call's `.result` and run only
# to fail. Each must let `skipped` through only under a real skip condition, never a constant.
#
# A wrapper whose call never legitimately skips uses `always() && <impl>.result != 'success'`
# and must not claim a skip is expected.
RSpec.describe ".github/workflows/ci.yml required-check wrappers" do
  CI_YML = File.join(InMemoryDomain::ROOT, ".github/workflows/ci.yml")
  REQUIRE_RESULT = "./.github/actions/require-result".freeze

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
    it "#{name} lets #{job.fetch("needs")}'s skip through only when its own skip condition holds" do
      impl = job.fetch("needs")
      condition = skip_condition(job)
      step = job.fetch("steps").find { |candidate| candidate["uses"] == REQUIRE_RESULT }

      if condition.nil?
        expect(job.fetch("if")).to eq("always() && needs.#{impl}.result != 'success'"),
                                   "#{name}'s if: must be either `always() && !(needs.#{impl}.result == 'success' || " \
                                   "(needs.#{impl}.result == 'skipped' && (<skip condition>)))` or, when nothing about " \
                                   "#{impl} ever legitimately skips, `always() && needs.#{impl}.result != 'success'`; " \
                                   "got #{job["if"].inspect}"
        expect(step.dig("with", "skip-expected")).to be_nil,
                                                     "#{name} tolerates no skip at all, so it must not claim one is expected"
      else
        expect(condition).to include("github.event_name"), "#{name}: the skip condition must be an expression, not a constant"
        expect(step.dig("with", "skip-expected")).to eq("${{ #{condition} }}")
      end

      expect(step.dig("with", "job")).to eq(impl)
      expect(step.dig("with", "result")).to eq("${{ needs.#{impl}.result }}")
    end
  end

  # The step every wrapper shares: it reports the result and fails, whatever it is given.
  describe "the require-result action" do
    let(:action) { YAML.load_file(File.join(InMemoryDomain::ROOT, REQUIRE_RESULT, "action.yml")) }
    let(:script) { action.dig("runs", "steps").first.fetch("run") }

    it "runs only to fail" do
      expect(script).to include("exit 1")
      expect(script).not_to include("exit 0"), "a wrapper runs only to fail, so its step must never pass"
    end

    it "reads its inputs through the environment, never into the script text" do
      expect(script).not_to include("${{")
    end

    it "is called by every wrapper, and the wrappers have no shell of their own" do
      self.class.wrappers.each_value do |job|
        expect(job.fetch("steps").filter_map { |step| step["run"] }).to be_empty
      end
    end
  end

  # Every job runs on `pull_request`, so a label gate would let a job that never ran on
  # the PR fail in the merge queue and eject the batch.
  it "gates no job on the retired full-ci label" do
    [CI_YML, File.join(InMemoryDomain::ROOT, ".github/workflows/ci-checks.yml")].each do |path|
      YAML.load_file(path).fetch("jobs").each do |name, job|
        expect(job["if"].to_s).not_to include("full-ci"),
                                      "#{File.basename(path)}'s #{name} still gates on the retired full-ci label: #{job["if"]}"
      end
    end
  end

  # `merge_group.base_sha` is the previous queue entry, not the target branch, so a path
  # gate diffing against it lets a gate-skipped PR carry a red one in ahead of it.
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

  # The merge queue already tested a push to main, so only the Postgres detector may take
  # a runner. A job skips on push by saying so, or by needing one that does.
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

  # A job with no timeout runs up to 360 minutes, holding one of the account's 20 runner slots.
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
