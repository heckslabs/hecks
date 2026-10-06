require "open3"

# Every lib file loads standalone in a fresh process, and the subsystem wrappers load in
# any order.
RSpec.describe "load hygiene", :io do
  ROOT_DIR = File.expand_path("..", __dir__) unless defined?(ROOT_DIR)
  LIB = File.join(ROOT_DIR, "lib")

  def load_in_subprocess(feature)
    Open3.capture3("ruby", "-I", LIB, "-e", "require #{feature.inspect}")
  end

  # bluebook internals are frozen, so their namespace wrappers carry the requires that
  # standalone loading needs; the wrappers are held to the standard, the internals exempt.
  BLUEBOOK_WRAPPERS = %w[
    hecks/bluebook hecks/bluebook/ir hecks/bluebook/dsl
    hecks/bluebook/expression
  ].freeze

  it "loads every lib file standalone, in a fresh process" do
    features = Dir[File.join(LIB, "hecks", "**", "*.rb")]
               .map { |file| file.sub("#{LIB}/", "").sub(/\.rb\z/, "") }
               .reject { |f| f.start_with?("hecks/bluebook/") && !BLUEBOOK_WRAPPERS.include?(f) }
               .sort

    failures = Queue.new
    work = Queue.new
    features.each { |feature| work << feature }
    8.times.map do
      Thread.new do
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
    end.each(&:join)

    broken = [].tap { |list| list << failures.pop until failures.empty? }
    expect(broken).to be_empty,
                      "these files no longer load standalone — each needs to require what it references:\n\n" \
                      "#{broken.sort.join("\n")}"
  end

  # io: false — only reads spec files, so it runs with the unit suite and the pre-push hook.
  it "lets no two spec files disagree about a top-level constant", io: false do
    # A constant assigned inside RSpec.describe lands on Object at any nesting depth, so two spec
    # files using one name share it and the last-loaded wins. Scanned at any indentation.
    # Same name with the same value is allowed.
    definitions = Hash.new { |h, k| h[k] = [] }
    Dir[File.join(ROOT_DIR, "spec", "**", "*_spec.rb")].each do |file|
      File.read(file).scan(/^\s+([A-Z][A-Z_0-9]*) *=[^=]/) do |(name)|
        definitions[name] << File.basename(file)
      end
    end

    shared_values = %w[BANKING_BLUEBOOK ROOT_DIR WIRE_BLUEBOOK SQLITE_ADAPTER]
    colliding = definitions.select { |name, files| files.uniq.size > 1 && !shared_values.include?(name) }

    expect(colliding).to be_empty,
                         "spec files sharing a top-level constant name:\n" \
                         "#{colliding.map { |name, files| "  #{name}: #{files.uniq.join(", ")}" }.join("\n")}"
  end

  # ADR 0033: a domain bound to a lazily-loaded plugin (PostgresEra) must boot in a fresh process.
  # spec_helper already requires the era plugin, so an in-process boot cannot see it unloaded.
  it "boots a domain bound to a lazily-loaded persistence plugin (PostgresEra) with nothing pre-required" do
    domain = File.join(ROOT_DIR, "examples/pizzas")
    script = "require 'hecks'; Hecks.boot(#{domain.inspect})"
    _out, err, status = Open3.capture3("ruby", "-I", LIB, "-e", script)

    expect(status.success?).to be(true),
                               "a fresh process could not boot a PostgresEra-bound domain with " \
                               "nothing pre-required — Adapters.autoload(:PostgresEra, ...) in " \
                               "adapters/driven.rb regressed:\n#{err.lines.first(10).join}"
  end

  it "loads the whole framework with the subsystem wrappers in reverse order" do
    wrappers = File.read(File.join(LIB, "hecks.rb"))
                   .scan(%r{^require_relative "(hecks/[^"]+)"}).flatten

    script = wrappers.reverse.map { |wrapper| "require #{wrapper.inspect}" }.join("; ")
    _out, err, status = Open3.capture3("ruby", "-I", LIB, "-e", script)

    expect(status.success?).to be(true),
                               "reversing the wrapper order broke the load — an order-dependence " \
                               "crept back in:\n#{err.lines.first(5).join}"
  end
end
