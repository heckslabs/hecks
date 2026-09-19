require "open3"

# The loading contract, made executable. Two facts hold across lib/:
#
#   1. Every file is self-sufficient — it requires what it references,
#      so it loads standalone, first, in an empty process. Nothing may
#      lean on some other file having loaded a dependency earlier.
#   2. The subsystem wrappers' require order is convenience, not load
#      order — the whole framework loads with the wrappers reversed.
#
# Without this spec, both would hold only by accident of history: the flat
# require list in lib/hecks.rb encodes the order files were added in, and
# nothing would name the moment a class-body constant reference quietly
# made that order load-bearing again. This spec names it, and the file it
# names is the one that grew the dependency.
RSpec.describe "load hygiene", :io do
  ROOT_DIR = File.expand_path("..", __dir__) unless defined?(ROOT_DIR)
  LIB = File.join(ROOT_DIR, "lib")

  def load_in_subprocess(feature)
    Open3.capture3("ruby", "-I", LIB, "-e", "require #{feature.inspect}")
  end

  # bluebook/** file contents are frozen by standing constraint, so a
  # bluebook internal cannot grow the requires standalone loading needs
  # (`extend Construct` at class body, contract.rb before contracts.rb).
  # Their namespace files carry those requires instead — so the wrappers
  # are held to the standard, and the internals are exempt.
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

  # io: false — this one only reads spec files, so it runs with the unit
  # suite and the pre-push hook instead of first failing in a Postgres shard.
  it "lets no two spec files disagree about a top-level constant", io: false do
    # A constant assigned inside an RSpec.describe block lands at top
    # level — the block captures its file's lexical scope, at any
    # nesting depth (a describe block is not a module or class, so
    # constant assignment always falls through to Object) — so two spec
    # files using the same constant name silently share one, last-loaded
    # wins, and the loser fails somewhere else entirely (measured twice:
    # a raw keywords here replaced a stringified keywords there and
    # surfaced as an order-dependent NoMethodError two files away ; a
    # corpus four levels deep in model_check_spec.rb collided with
    # domain_refusal_spec's, invisible to a check that only matches
    # 2-space indent — a nested describe's constants sit one level deeper
    # and would go unscanned entirely). Matched at any indentation here,
    # for that reason.
    # Same name, same value is harmless and allowed; same name,
    # different definition site with different content is the bug class.
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
                         "#{colliding.map { |name, files| "  #{name}: #{files.uniq.join(', ')}" }.join("\n")}"
  end

  # ADR 0033's own contract, exercised the one way that can catch it: a
  # domain bound to a loadable persistence plugin (PostgresEra) has to
  # boot with nothing pre-required, in a genuinely fresh process — every
  # spec in this suite shares one process with `spec_helper.rb`'s own
  # eager `require "hecks/ports/persistence/plugins/era"`, so a
  # `Hecks.boot` call inside an ordinary example can never actually
  # observe the plugin unloaded, no matter what regresses in
  # `adapters/driven.rb`'s own `Adapters.autoload(:PostgresEra, ...)`.
  # Found live: exactly that autoload missing (a plain `require_relative`
  # comment with no code behind it) broke every one of ~15 generic
  # `bin/*` tools against every PostgresEra-bound example domain, with
  # the whole suite green throughout.
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
