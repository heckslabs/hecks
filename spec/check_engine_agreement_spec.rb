require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"

# bin/check_engine_agreement is a SCRIPT, not a library — same reasoning
# bin_stores_spec.rb's own header gives: there's nothing to require, so
# this runs it as a real subprocess (Open3) against real files.
#
# The POSITIVE case runs it against the real, current repo: Tiers 1-4
# already unified the two engines behind QuerySpecification::Common::
# Comparison, so this is the proof that state stays "0 problems" —
# not merely that the script runs.
#
# The NEGATIVE cases run it against a TEMP COPY of the six files it
# reads (the shared comparison module, the two engine files, and the
# three cross-engine agreement specs), each deliberately mutated to
# reintroduce exactly one of the two shipped bugs this mechanism exists
# to catch. `HECKS_CHECK_ENGINE_AGREEMENT_ROOT` points the script at
# that copy instead of the real repo — `Hecks::Vocabulary` itself still
# loads for real (the script's own `require "hecks"` is unconditional,
# resolved from its own real `lib/`), so the DECLARED closed set is
# always the real nine comparators; only WHERE it looks for the shared
# case and the agreement specs is faked.
RSpec.describe "bin/check_engine_agreement" do
  # Namespaced, not a bare SCRIPT — see load_hygiene_spec.rb's own "no two
  # spec files disagree about a top-level constant" check: a constant
  # assigned inside a `describe` block lands at Object (top level, not on
  # the example group), so a bare `SCRIPT` here silently collided with
  # project_tenant_spec.rb's own bare `SCRIPT` — whichever spec file's
  # `require` ran last during rspec's load phase won, and every example in
  # THIS file ended up shelling out to bin/project_tenant instead. Follows
  # bin_stores_spec.rb's own `BIN_STORES_SCRIPT` naming for the same reason.
  CHECK_ENGINE_AGREEMENT_SCRIPT = File.join(InMemoryDomain::ROOT, "bin/check_engine_agreement").freeze

  TRACKED_RELATIVE_PATHS = %w[
    lib/hecks/ports/query/in_memory.rb
    lib/hecks/runtime/query_interpreter.rb
    lib/hecks/query_specification/common/comparison.rb
    spec/adapters/query_agreement_spec.rb
    spec/query_none_in_state_aggregate_level_growth_spec.rb
    spec/query_none_in_state_growth_spec.rb
  ].freeze

  # A faithful copy of the six real, tracked files under a scratch root
  # — every OTHER comparator stays fully covered, so a mutation below
  # isolates exactly the one gap it introduces rather than accidentally
  # tripping on some unrelated, pre-existing gap.
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
    # All nine declared comparators named in the clean report, proving
    # the declared set was actually read (not silently empty — see the
    # script's own refusal for that case).
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
      # Delete the `gt` case alone — every other comparator's case (and
      # every spec example) is left untouched.
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

      # Strip every explicit `gt:` occurrence (and the one example whose
      # DESCRIPTION names it) from all three agreement-suite copies,
      # leaving comparison.rb's own `gt` case exactly as it is — this
      # isolates the SPEC gap from the CASE gap the previous example
      # covers.
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
      # A DUPLICATE, private re-implementation living ALONGSIDE the real
      # `Comparison.holds?` call — exactly the shape the original bug
      # took: not a replacement, a second copy nobody deletes.
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
