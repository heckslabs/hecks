require "yaml"
require "hecks/behaviors"
require "hecks/rust_build/kernel_engine"

# Which `.behaviors` tests the kernel can run, and the named list of tests whose kernel outcome
# still differs from the in-process one (`spec/behaviors/kernel_differences.yml`).
module BehaviorsOnKernel
  ROOT = File.expand_path("../..", __dir__)
  GLOBS = %w[examples/**/*.behaviors lib/hecks/**/*.behaviors spec/**/*.behaviors].freeze
  DIFFERENCES = File.join(ROOT, "spec", "behaviors", "kernel_differences.yml")

  # One test to twin, or one whole suite left pending because its domain has no kernel feature.
  Case = Struct.new(:file, :test, :suite, :reason, :pending, keyword_init: true) do
    # @return [String] the example's description
    def title
      return "#{file} runs on the kernel" if pending
      return "#{file}: #{test.description} (still differs: #{reason})" if reason

      "#{file}: #{test.description}"
    end
  end

  module_function

  # @return [Array<String>] every `.behaviors` file, relative to the repository root, sorted
  def files = GLOBS.flat_map { |glob| Dir.glob(glob, base: ROOT) }.sort

  # @return [Array<Case>] a case per test of each suite with a kernel feature, and a pending case
  #   per suite without one; a file that does not parse is left to the in-process leg
  def cases
    listed = differences
    files.flat_map do |file|
      parsed = Hecks::Behaviors.parse(File.join(ROOT, file))
      parsed.parse_error ? [] : cases_of(file, parsed.suite, parsed.tests, listed)
    end
  end

  # @return [Array<Case>] the cases of one parsed suite
  def cases_of(file, suite, tests, listed)
    feature = feature(suite)
    unless feature && Hecks::RustBuild::KernelEngine.feature?(feature)
      return [Case.new(file: file, suite: suite, pending: "rust/Cargo.toml declares no feature #{feature.inspect}")]
    end

    tests.map { |test| Case.new(file: file, test: test, suite: suite, reason: listed[[file, test.description]]) }
  end

  # @param suite [Hecks::Behaviors::BehaviorsSuite] a parsed suite
  # @return [String, nil] the Cargo feature its first bluebook's directory names
  def feature(suite)
    bluebook = Array(suite.loads).find { |file| file.end_with?(".bluebook") }
    bluebook && Hecks::RustBuild::KernelEngine.feature_of(File.dirname(File.expand_path(bluebook)))
  end

  # @return [Hash{Array(String, String) => String}] each listed test, as `[file, description]`,
  #   with the reason its kernel outcome differs
  def differences
    Array(YAML.load_file(DIFFERENCES)).to_h { |entry| [[entry["file"], entry["test"]], entry["reason"]] }
  end

  # @return [Array<Array(String, String)>] listed tests that no `.behaviors` file holds
  def unknown_differences
    known = files.flat_map do |file|
      parsed = Hecks::Behaviors.parse(File.join(ROOT, file))
      parsed.parse_error ? [] : parsed.tests.map { |test| [file, test.description] }
    end
    differences.keys - known
  end

  # @param kase [Case] one test
  # @return [String, nil] why the case does not end as the list says, or nil when it does
  def mismatch(kase)
    ruby, kernel = %i[ruby kernel].map { |engine| outcome(kase.test, kase.suite, engine) }
    agreed = ruby.first == kernel.first
    return "in-process #{ruby.inspect}, kernel #{kernel.inspect}" if !agreed && !kase.reason
    return "listed (#{kase.reason}) but both engines answer #{ruby.inspect}: remove it" if agreed && kase.reason

    nil
  end

  # @return [Array(Symbol, String)] the test's status and message on that engine
  def outcome(test, suite, engine)
    runtime = Hecks::Behaviors::Expectations.runtime_for(suite, engine: engine)
    run = Hecks::Behaviors::Expectations.run_one(test, suite, runtime: runtime)
    [run.status, run.message]
  rescue StandardError => e
    [:error, "#{e.class}: #{e.message}"]
  end
end
