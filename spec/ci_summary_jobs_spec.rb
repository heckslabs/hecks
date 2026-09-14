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
# lets `skipped` through without a condition, the condition is an
# expression (never a constant), and every call gated on the light PR set
# (PR #666) names that same condition as an expected skip.
RSpec.describe ".github/workflows/ci.yml required-check wrappers" do
  CI_YML = File.join(InMemoryDomain::ROOT, ".github/workflows/ci.yml")
  LIGHT_SET = "github.event_name == 'pull_request' && !contains(github.event.pull_request.labels.*.name, 'full-ci')".freeze

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
      expect(condition).not_to be_nil,
                               "#{name}'s if: must be `always() && !(needs.#{impl}.result == 'success' || " \
                               "(needs.#{impl}.result == 'skipped' && (<skip condition>)))`, got #{job['if'].inspect}"
      expect(condition).to include("github.event_name"), "#{name}: the skip condition must be an expression, not a constant"

      step = job.fetch("steps").first
      expect(step.dig("env", "SKIP_EXPECTED")).to eq("${{ #{condition} }}")
      expect(step.fetch("run")).to include("exit 1")
      expect(step.fetch("run")).not_to include("exit 0"), "#{name} runs only to fail — its step must never pass"

      call_if = self.class.jobs.fetch(impl)["if"].to_s
      if call_if.include?("full-ci")
        expect(condition).to include(LIGHT_SET),
                             "#{impl} skips on the light PR set (its own if: #{call_if}), so #{name} must expect that skip"
      end
    end
  end
end
