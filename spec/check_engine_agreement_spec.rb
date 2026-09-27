require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"

# bin/check_engine_agreement is a script, so this runs it as a subprocess. The negative cases
# mutate a scratch copy of the files it reads, selected by `HECKS_CHECK_ENGINE_AGREEMENT_ROOT`;
# the declared comparator set still comes from the real `Hecks::Vocabulary`.
RSpec.describe "bin/check_engine_agreement" do
  # Namespaced because a constant assigned in a `describe` block lands on Object; a bare
  # `SCRIPT` collided with project_tenant_spec.rb's (see load_hygiene_spec.rb).
  CHECK_ENGINE_AGREEMENT_SCRIPT = File.join(InMemoryDomain::ROOT, "bin/check_engine_agreement").freeze

  TRACKED_RELATIVE_PATHS = %w[
    lib/hecks/ports/query/in_memory.rb
    lib/hecks/runtime/query_interpreter.rb
    lib/hecks/query_specification/common/comparison.rb
    spec/adapters/query_agreement_spec.rb
    spec/query_none_in_state_aggregate_level_growth_spec.rb
    spec/query_none_in_state_growth_spec.rb
  ].freeze

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
    Open3.capture3({ "HECKS_CHECK_ENGINE_AGREEMENT_ROOT" => dir }, CHECK_ENGINE_AGREEMENT_SCRIPT)
  end

  it "passes cleanly against the real, current repo — Tiers 1-4 already unified the two engines" do
    stdout, stderr, status = Open3.capture3(CHECK_ENGINE_AGREEMENT_SCRIPT)

    expect(status).to be_success, "expected 0 problems, got:\n#{stdout}#{stderr}"
    expect(stdout).to include("0 problems")
    # Proves the declared set was actually read rather than silently empty.
    %w[eq ne gt gte lt lte in contains none_in_state].each do |comparator|
      expect(stdout).to include(comparator)
    end
  end

  it "refuses cleanly rather than crashing uninformatively against a scratch root with nothing tracked" do
    Dir.mktmpdir("check-engine-agreement-empty-") do |dir|
      _stdout, stderr, status = run_against(dir)

      expect(status).not_to be_success
      expect(stderr).not_to be_empty
    end
  end

  it "flags a declared comparator with NO shared-module case (the 10th-comparator gap comparison.rb's own `else` guards)" do
    Dir.mktmpdir("check-engine-agreement-") do |dir|
      clone_tracked_tree(dir)

      comparison_path = File.join(dir, "lib/hecks/query_specification/common/comparison.rb")
      source = File.read(comparison_path)
      # Delete the `gt` case alone.
      mutated = source.sub(/\s*when\s+"gt"\s+then\s+ordered\?\(held, want\) && held > want\n/, "\n")
      raise "fixture did not change — regex no longer matches comparison.rb's own `gt` case" if mutated == source

      File.write(comparison_path, mutated)

      stdout, stderr, status = run_against(dir)

      expect(status).not_to be_success
      expect(stdout + stderr).to include('"gt"')
      expect(stdout + stderr).to include("no `when` case")
    end
  end

  it "flags a declared comparator with a shared case but NO cross-engine agreement spec" do
    Dir.mktmpdir("check-engine-agreement-") do |dir|
      clone_tracked_tree(dir)

      # Strip every `gt:` from the three agreement specs, leaving comparison.rb's `gt`
      # case intact, to isolate the spec gap from the case gap.
      %w[
        spec/adapters/query_agreement_spec.rb
        spec/query_none_in_state_aggregate_level_growth_spec.rb
        spec/query_none_in_state_growth_spec.rb
      ].each do |relative|
        path = File.join(dir, relative)
        File.write(path, File.read(path).gsub(/(?<![A-Za-z0-9_])gt(?![A-Za-z0-9_])\s*:/, "eq:"))
      end

      stdout, stderr, status = run_against(dir)

      expect(status).not_to be_success
      expect(stdout + stderr).to include('"gt"')
      expect(stdout + stderr).to include("no example in")
    end
  end

  it "flags an engine file that grows its own comparator `when`, instead of routing through Comparison.holds?" do
    Dir.mktmpdir("check-engine-agreement-") do |dir|
      clone_tracked_tree(dir)

      in_memory_path = File.join(dir, "lib/hecks/ports/query/in_memory.rb")
      # A second, private copy of the comparator logic alongside the real `Comparison.holds?`.
      poisoned = File.read(in_memory_path).sub(
        "module_function\n",
        "module_function\n\n        def duplicated_eq_check(operation)\n          " \
        "case operation\n          when \"eq\" then true\n          end\n        end\n"
      )
      raise "fixture did not change — module_function anchor not found in in_memory.rb" if poisoned == File.read(in_memory_path)

      File.write(in_memory_path, poisoned)

      stdout, stderr, status = run_against(dir)

      expect(status).not_to be_success
      expect(stdout + stderr).to include("in_memory.rb")
      expect(stdout + stderr).to include('`when "eq"`')
    end
  end
end
