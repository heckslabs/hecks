require "open3"

# Every lib file loads standalone in a fresh process, and the subsystem wrappers load in
# any order.
RSpec.describe "load hygiene", :io do
  ROOT_DIR = File.expand_path("..", __dir__) unless defined?(ROOT_DIR)
  LIB = File.join(ROOT_DIR, "lib")

  def capture_ruby(script) = Open3.capture3("ruby", "-I", LIB, "-e", script)

  def load_in_subprocess(feature) = capture_ruby("require #{feature.inspect}")

  # bluebook internals are frozen, so their namespace wrappers carry the requires that
  # standalone loading needs; the wrappers are held to the standard, the internals exempt.
  BLUEBOOK_WRAPPERS = %w[
    hecks/bluebook hecks/bluebook/ir hecks/bluebook/dsl
    hecks/bluebook/expression
  ].freeze

  def standalone_features
    Dir[File.join(LIB, "hecks", "**", "*.rb")]
      .map { |file| file.sub("#{LIB}/", "").delete_suffix(".rb") }
      .reject { |f| f.start_with?("hecks/bluebook/") && !BLUEBOOK_WRAPPERS.include?(f) }
      .sort
  end

  # Takes features off `work` until it is empty, adding a line to `failures` for each that fails.
  def load_features_from(work, failures)
    until work.empty?
      feature = begin
        work.pop(true)
      rescue ThreadError
        break
      end
      _out, err, status = load_in_subprocess(feature)
      failures << "#{feature}:\n#{err.lines.first(3).join}" unless status.success?
    end
  end

  def broken_features(features)
    failures = Queue.new
    work = Queue.new
    features.each { |feature| work << feature }
    Array.new(8) { Thread.new { load_features_from(work, failures) } }.each(&:join)
    [].tap { |list| list << failures.pop until failures.empty? }
  end

  it "loads every lib file standalone, in a fresh process" do
    broken = broken_features(standalone_features)

    expect(broken).to be_empty,
                      "these files no longer load standalone — each needs to require what it references:\n\n" \
                      "#{broken.sort.join("\n")}"
  end

  # A constant assigned inside RSpec.describe lands on Object at any nesting depth, so two spec
  # files using one name share it and the last-loaded wins. Scanned at any indentation.
  def constant_definitions
    definitions = Hash.new { |h, k| h[k] = [] }
    Dir[File.join(ROOT_DIR, "spec", "**", "*_spec.rb")].each do |file|
      File.read(file).scan(/^\s+([A-Z][A-Z_0-9]*) *=[^=]/) do |(name)|
        definitions[name] << File.basename(file)
      end
    end
    definitions
  end

  # Same name with the same value is allowed.
  def shared_constant_names = ["BANKING_BLUEBOOK", "ROOT_DIR", "WIRE_BLUEBOOK", "SQLITE_ADAPTER"]

  # io: false — only reads spec files, so it runs with the unit suite and the pre-push hook.
  it "lets no two spec files disagree about a top-level constant", io: false do
    colliding = constant_definitions.select { |name, files| files.uniq.size > 1 && !shared_constant_names.include?(name) }

    expect(colliding).to be_empty,
                         "spec files sharing a top-level constant name:\n" \
                         "#{colliding.map { |name, files| "  #{name}: #{files.uniq.join(", ")}" }.join("\n")}"
  end

  # ADR 0033: a domain bound to a lazily-loaded plugin (PostgresEra) must boot in a fresh process.
  # spec_helper already requires the era plugin, so an in-process boot cannot see it unloaded.
  it "boots a domain bound to a lazily-loaded persistence plugin (PostgresEra) with nothing pre-required" do
    _out, err, status = capture_ruby("require 'hecks'; Hecks.boot(#{File.join(ROOT_DIR, "examples/pizzas").inspect})")

    expect(status.success?).to be(true),
                               "a fresh process could not boot a PostgresEra-bound domain with " \
                               "nothing pre-required — Adapters.autoload(:PostgresEra, ...) in " \
                               "adapters/driven.rb regressed:\n#{err.lines.first(10).join}"
  end

  def top_level_wrappers
    File.read(File.join(LIB, "hecks.rb")).scan(%r{^require_relative "(hecks/[^"]+)"}).flatten
  end

  it "loads the whole framework with the subsystem wrappers in reverse order" do
    script = top_level_wrappers.reverse.map { |wrapper| "require #{wrapper.inspect}" }.join("; ")
    _out, err, status = capture_ruby(script)

    expect(status.success?).to be(true),
                               "reversing the wrapper order broke the load — an order-dependence " \
                               "crept back in:\n#{err.lines.first(5).join}"
  end
end
