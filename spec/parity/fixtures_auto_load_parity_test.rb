# Hecks::Parity::FixturesAutoLoadParityTest
#
# Locks the i4-gap-8 contract: both the Ruby runner
# (bin/hecks-behaviors) and the Rust runner
# (`hecks-life behaviors`) auto-load a sibling `.fixtures` file
# and produce identical pass/fail/error output on a fixture-dependent
# behaviors suite. Drift between runners here is a hard failure.
#
# The test fixture itself is minimal and self-contained:
#
#   - `store.bluebook`   one aggregate (Store) with a query ByAll
#   - `store.fixtures`   seeds two Store records (LeftShelf, RightShelf)
#   - `store.behaviors`  query test expecting count == 2
#
# Without fixtures auto-load the query returns 0 records; the test
# fails. With auto-load the query returns 2; the test passes. Both
# runners must reach the SAME verdict, whether pass or fail.
#
# Run: bundle exec ruby -Ilib spec/parity/fixtures_auto_load_parity_test.rb
require "open3"
require "tmpdir"
require "fileutils"

HECKS_LIFE  = File.expand_path("../../hecks_life/target/release/hecks-life", __dir__)
RUBY_RUNNER = File.expand_path("../../bin/hecks-behaviors", __dir__)

abort "hecks-life not built" unless File.executable?(HECKS_LIFE)
abort "ruby runner missing"  unless File.executable?(RUBY_RUNNER)

BLUEBOOK = <<~BLUEBOOK
  Hecks.bluebook "Store", version: "2026.04.21.1" do
    vision "Minimal store for fixtures auto-load parity test"
    category "body"
    core

    aggregate "Shelf", "One shelf in a store" do
      attribute :label, String
      attribute :stock, Integer

      query "ByAll" do
        description "Return every shelf on the domain"
      end
    end
  end
BLUEBOOK

FIXTURES = <<~FIXTURES
  Hecks.fixtures "Store" do
    aggregate "Shelf" do
      fixture "LeftShelf",  label: "left",  stock: 5
      fixture "RightShelf", label: "right", stock: 3
    end
  end
FIXTURES

BEHAVIORS = <<~BEHAVIORS
  Hecks.behaviors "Store" do
    vision "Verify fixtures auto-load makes seeded records visible"

    test "ByAll returns fixture-seeded shelves" do
      tests "ByAll", on: "Shelf", kind: :query
      expect count: 2
    end
  end
BEHAVIORS

# Write all three files into a fresh temp dir and return the .behaviors path.
def write_fixture_pack(dir)
  File.write(File.join(dir, "store.bluebook"),  BLUEBOOK)
  File.write(File.join(dir, "store.fixtures"),  FIXTURES)
  File.write(File.join(dir, "store.behaviors"), BEHAVIORS)
  File.join(dir, "store.behaviors")
end

# Tail summary line into { pass:, fail:, error: }.
def parse_summary(out)
  m = out.match(/(\d+) passed,\s+(\d+) failed,\s+(\d+) errored/)
  return { pass: 0, fail: 0, error: 0 } unless m
  { pass: m[1].to_i, fail: m[2].to_i, error: m[3].to_i }
end

# Per-test verdict map — "desc" → :pass / :fail / :error.
def parse_verdicts(out)
  v = {}
  out.each_line do |line|
    case line
    when /\A✓ (.+)\Z/ then v[$1.strip] = :pass
    when /\A✗ (.+)\Z/ then v[$1.strip] = :fail
    when /\A⚠ (.+)\Z/ then v[$1.strip] = :error
    end
  end
  v
end

# True when the runner logged a "fixtures:" path — proves the
# auto-loader fired (not just "tests happened to pass without it").
def loaded_fixtures?(out)
  out.include?("fixtures: ")
end

divergent = 0

Dir.mktmpdir("hecks-fixtures-parity-") do |dir|
  behaviors_path = write_fixture_pack(dir)

  ruby_out, = Open3.capture2e(RUBY_RUNNER, behaviors_path)
  rust_out, = Open3.capture2e(HECKS_LIFE, "behaviors", behaviors_path)

  ruby_sum = parse_summary(ruby_out); rust_sum = parse_summary(rust_out)
  ruby_v   = parse_verdicts(ruby_out); rust_v  = parse_verdicts(rust_out)

  unless loaded_fixtures?(ruby_out)
    puts "✗ ruby runner did not log a fixtures: path"
    puts ruby_out
    divergent += 1
  end
  unless loaded_fixtures?(rust_out)
    puts "✗ rust runner did not log a fixtures: path"
    puts rust_out
    divergent += 1
  end

  if ruby_sum == rust_sum && ruby_v == rust_v
    puts "✓ auto-loaded fixtures: identical verdicts — #{ruby_sum.inspect}"
  else
    puts "✗ auto-loaded fixtures: runners diverge"
    puts "    rust: #{rust_sum.inspect}  #{rust_v.inspect}"
    puts "    ruby: #{ruby_sum.inspect}  #{ruby_v.inspect}"
    puts "\n--- ruby output ---\n#{ruby_out}"
    puts "\n--- rust output ---\n#{rust_out}"
    divergent += 1
  end

  # Positive assertion: both runners should have found the seeded
  # records (count == 2). If count is 0 somewhere the auto-loader
  # didn't seed into the query path for that runner — real bug.
  if ruby_sum[:pass] != 1 || rust_sum[:pass] != 1
    puts "✗ expected 1 passing test per runner (count: 2 assertion)"
    puts "    ruby: #{ruby_sum.inspect}"
    puts "    rust: #{rust_sum.inspect}"
    divergent += 1
  end
end

exit(divergent.zero? ? 0 : 1)
