require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

# `hecks check_engine_agreement` (Hecks::CLI::CheckEngineAgreement) runs as a subprocess. The
# negative cases mutate a scratch copy of the files it reads, selected by
# `HECKS_CHECK_ENGINE_AGREEMENT_ROOT`; the declared comparator set still comes from the real
# `Hecks::Vocabulary`.
RSpec.describe "hecks check_engine_agreement" do
  # Namespaced because a constant assigned in a `describe` block lands on Object (see
  # load_hygiene_spec.rb). The child's whole program is the library entry point.
  CHECK_ENGINE_AGREEMENT_CHILD =
    '$LOAD_PATH.unshift(File.join(Dir.pwd, "lib")); require "hecks/cli/check_engine_agreement"; ' \
    'exit(Hecks::CLI::CheckEngineAgreement.call(root: ENV["HECKS_CHECK_ENGINE_AGREEMENT_ROOT"] || Dir.pwd))'.freeze

  def check_engine_agreement(env = {})
    Open3.capture3(env, RbConfig.ruby, "-e", CHECK_ENGINE_AGREEMENT_CHILD, chdir: InMemoryDomain::ROOT)
  end

  TRACKED_RELATIVE_PATHS = %w[
    lib/hecks/ports/query/in_memory.rb
    lib/hecks/runtime/query_interpreter.rb
    lib/hecks/query_specification/common/comparison.rb
    spec/adapters/query_agreement_spec.rb
    spec/query_none_in_state_aggregate_level_growth_spec.rb
    spec/query_none_in_state_growth_spec.rb
  ].freeze

  AGREEMENT_SPECS = %w[
    spec/adapters/query_agreement_spec.rb
    spec/query_none_in_state_aggregate_level_growth_spec.rb
    spec/query_none_in_state_growth_spec.rb
  ].freeze

  DECLARED_COMPARATORS = %w[eq ne gt gte lt lte in contains none_in_state].freeze

  # Copies the six tracked files so each mutation below isolates exactly one gap.
  def clone_tracked_tree(dir)
    TRACKED_RELATIVE_PATHS.each do |relative|
      source = File.join(InMemoryDomain::ROOT, relative)
      target = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(source, target)
    end
  end

  def run_against(dir)
    check_engine_agreement({ "HECKS_CHECK_ENGINE_AGREEMENT_ROOT" => dir })
  end

  # Clones the tracked tree, lets the block mutate it, runs the check against it, and answers
  # whether it succeeded and everything it printed.
  def report_after_mutating
    Dir.mktmpdir("check-engine-agreement-") do |dir|
      clone_tracked_tree(dir)
      yield dir
      stdout, stderr, status = run_against(dir)
      [status.success?, stdout + stderr]
    end
  end

  # Delete the `gt` case alone from the shared comparison module.
  def drop_gt_case(dir)
    comparison_path = File.join(dir, "lib/hecks/query_specification/common/comparison.rb")
    source = File.read(comparison_path)
    mutated = source.sub(/\s*when\s+"gt"\s+then\s+ordered\?\(held, want\) && held > want\n/, "\n")
    raise "fixture did not change — regex no longer matches comparison.rb's own `gt` case" if mutated == source

    File.write(comparison_path, mutated)
  end

  # Strip every `gt:` from the three agreement specs, leaving comparison.rb's `gt`
  # case intact, to isolate the spec gap from the case gap.
  def strip_gt_from_agreement_specs(dir)
    AGREEMENT_SPECS.each do |relative|
      path = File.join(dir, relative)
      File.write(path, File.read(path).gsub(/(?<![A-Za-z0-9_])gt(?![A-Za-z0-9_])\s*:/, "eq:"))
    end
  end

  # A second, private copy of the comparator logic alongside the real `Comparison.holds?`.
  def grow_private_comparator(dir)
    in_memory_path = File.join(dir, "lib/hecks/ports/query/in_memory.rb")
    original = File.read(in_memory_path)
    poisoned = original.sub("module_function\n", "module_function\n\n        def duplicated_eq_check(operation)\n          " \
                                                 "case operation\n          when \"eq\" then true\n          end\n        end\n")
    raise "fixture did not change — module_function anchor not found in in_memory.rb" if poisoned == original

    File.write(in_memory_path, poisoned)
  end

  it "passes cleanly against the real, current repo — Tiers 1-4 already unified the two engines", :aggregate_failures do
    stdout, stderr, status = check_engine_agreement

    expect(status).to be_success, "expected 0 problems, got:\n#{stdout}#{stderr}"
    expect(stdout).to include("0 problems")
    # Proves the declared set was actually read rather than silently empty.
    expect(stdout).to include(*DECLARED_COMPARATORS)
  end

  it "refuses cleanly rather than crashing uninformatively against a scratch root with nothing tracked", :aggregate_failures do
    Dir.mktmpdir("check-engine-agreement-empty-") do |dir|
      _stdout, stderr, status = run_against(dir)

      expect(status).not_to be_success
      expect(stderr).not_to be_empty
    end
  end

  it "flags a declared comparator with NO shared-module case (the " \
     "10th-comparator gap comparison.rb's own `else` guards)", :aggregate_failures do
    succeeded, report = report_after_mutating { |dir| drop_gt_case(dir) }

    expect(succeeded).to be(false)
    expect(report).to include('"gt"', "no `when` case")
  end

  it "flags a declared comparator with a shared case but NO cross-engine agreement spec", :aggregate_failures do
    succeeded, report = report_after_mutating { |dir| strip_gt_from_agreement_specs(dir) }

    expect(succeeded).to be(false)
    expect(report).to include('"gt"', "no example in")
  end

  it "flags an engine file that grows its own comparator `when`, " \
     "instead of routing through Comparison.holds?", :aggregate_failures do
    succeeded, report = report_after_mutating { |dir| grow_private_comparator(dir) }

    expect(succeeded).to be(false)
    expect(report).to include("in_memory.rb", '`when "eq"`')
  end
end
