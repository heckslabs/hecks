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

  # A wrapper whose `if:` carries no skip condition tolerates no skip at all.
  def expect_no_skip_tolerated(name, job, step)
    impl = job.fetch("needs")
    message = "#{name}'s if: must be either `always() && !(needs.#{impl}.result == 'success' || " \
              "(needs.#{impl}.result == 'skipped' && (<skip condition>)))` or, when nothing about " \
              "#{impl} ever legitimately skips, `always() && needs.#{impl}.result != 'success'`; got #{job["if"].inspect}"

    expect(job.fetch("if")).to eq("always() && needs.#{impl}.result != 'success'"), message
    expect(step.dig("with", "skip-expected")).to be_nil, "#{name} tolerates no skip at all, so it must not claim one is expected"
  end

  def expect_skip_expected(name, condition, step)
    expect(condition).to include("github.event_name"), "#{name}: the skip condition must be an expression, not a constant"
    expect(step.dig("with", "skip-expected")).to eq("${{ #{condition} }}")
  end

  wrappers.each do |name, job|
    it "#{name} lets #{job.fetch("needs")}'s skip through only when its own skip condition holds", :aggregate_failures do
      condition = skip_condition(job)
      step = job.fetch("steps").find { |candidate| candidate["uses"] == REQUIRE_RESULT }

      condition.nil? ? expect_no_skip_tolerated(name, job, step) : expect_skip_expected(name, condition, step)
      expect(step.dig("with", "job")).to eq(job.fetch("needs"))
      expect(step.dig("with", "result")).to eq("${{ needs.#{job.fetch("needs")}.result }}")
    end
  end

  # The step every wrapper shares: it reports the result and fails, whatever it is given.
  describe "the require-result action" do
    let(:action) { YAML.load_file(File.join(InMemoryDomain::ROOT, REQUIRE_RESULT, "action.yml")) }
    let(:script) { action.dig("runs", "steps").first.fetch("run") }

    it "runs only to fail", :aggregate_failures do
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

  def workflow_files(pattern) = Dir[File.join(InMemoryDomain::ROOT, pattern)]

  # Every job of the given workflow files as [path, name, job]; a file with no jobs is an error
  # unless `lenient`.
  def workflow_jobs(paths, lenient: false)
    paths.flat_map do |path|
      doc = YAML.load_file(path)
      (lenient ? doc.fetch("jobs", {}) : doc.fetch("jobs")).map { |name, job| [path, name, job] }
    end
  end

  def job_label(path, name) = "#{File.basename(path)}'s #{name}"

  # Every job runs on `pull_request`, so a label gate would let a job that never ran on
  # the PR fail in the merge queue and eject the batch.
  it "gates no job on the retired full-ci label" do
    paths = [CI_YML, File.join(InMemoryDomain::ROOT, ".github/workflows/ci-checks.yml")]
    gated = workflow_jobs(paths).select { |_, _, job| job["if"].to_s.include?("full-ci") }

    expect(gated.map { |path, name, _| job_label(path, name) }).to be_empty, "still gate on the retired full-ci label"
  end

  def uncommented(script) = script.to_s.gsub(/^\s*#.*$/, "")

  def reads_base_sha?(job)
    job.fetch("steps", []).any? { |step| uncommented(step["run"]).include?("merge_group.base_sha") }
  end

  # `merge_group.base_sha` is the previous queue entry, not the target branch, so a path
  # gate diffing against it lets a gate-skipped PR carry a red one in ahead of it.
  it "diffs no merge group against the previous queue entry" do
    jobs = workflow_jobs(workflow_files(".github/{workflows,actions}/**/*.yml"), lenient: true)
    reading = jobs.select { |_, _, job| reads_base_sha?(job) }
    message = "read merge_group.base_sha — diff against `git merge-base origin/<base_ref> <sha>` instead"

    expect(reading.map { |path, name, _| job_label(path, name) }).to be_empty, message
  end

  # A workflow's triggers: YAML reads the key `on` as `true`.
  def triggers_of(path)
    doc = YAML.load_file(path)
    on = doc.fetch(true, doc["on"])
    on.is_a?(Hash) ? on : {}
  end

  # `main` takes pushes with no gate, so a push's run is what reports where each RequiredCheck
  # stands, and promotion reads it. A job skipped on a push reports as passed, which would carry
  # an untested commit to `stable`: no job may name `push` as an event to skip on.
  it "skips no job on a push to main" do
    jobs = workflow_jobs(workflow_files(".github/workflows/ci*.yml"))
    skipping = jobs.select { |_, _, job| job["if"].to_s.include?("'push'") }

    expect(skipping.map { |path, name, _| job_label(path, name) }).to be_empty, "skip on a push to main"
  end

  # The merge queue is gone: `main` takes pushes directly, and `stable` is moved by promote.yml.
  it "has no merge_group trigger" do
    queued = workflow_files(".github/workflows/*.yml").select { |path| triggers_of(path).key?("merge_group") }

    expect(queued.map { |path| File.basename(path) }).to be_empty, "still trigger on merge_group"
  end

  # A job with no timeout runs up to 360 minutes, holding one of the account's 20 runner slots.
  it "gives every job that takes a runner a timeout" do
    running = workflow_jobs(workflow_files(".github/workflows/*.yml")).reject { |_, _, job| job.key?("uses") }
    untimed = running.reject { |_, _, job| job["timeout-minutes"].is_a?(Integer) && job["timeout-minutes"] <= 60 }

    expect(untimed.map { |path, name, _| job_label(path, name) }).to be_empty, "need a timeout-minutes of at most 60"
  end
end
