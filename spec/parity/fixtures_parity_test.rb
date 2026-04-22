# Hecks::Parity::FixturesParityTest
#
# Runs every .fixtures file through the Ruby DSL builder
# (Hecks.fixtures → FixturesBuilder) and through the Rust parser
# (`hecks-life dump <file>` — content-routed via fixtures_parser),
# then diffs the IRs. Drift is a hard contract failure.
#
# A .fixtures IR is a (domain_name, [Fixture]) pair. Each Fixture is
# an (aggregate_name, name?, attributes) tuple. The Ruby and Rust
# parsers produce structurally identical lists for any well-formed
# input — that's the contract this guards.
#
# Run: bundle exec ruby -Ilib spec/parity/fixtures_parity_test.rb
#
require "open3"
require "json"

HECKS_LIFE = File.expand_path("../../hecks_life/target/release/hecks-life", __dir__)
abort "hecks-life not built" unless File.executable?(HECKS_LIFE)

require "hecks"
require "hecks/dsl/fixtures_builder"

def normalize_attrs(h)
  # Both runtimes serialize attribute values as the source token. Ruby's
  # builder keeps them in their native types (Integer, Float, String,
  # etc.); the Rust parser keeps them as the verbatim string. To
  # diff, stringify both, trim quotes, sort keys (Rust's
  # serde_json::Map serializes alphabetically without preserve_order),
  # and collapse internal whitespace so `[ "a", "b" ]` (source-form)
  # matches `["a", "b"]` (Ruby Array#inspect form).
  h.transform_values { |v|
    s = v.to_s.sub(/\A"/, "").sub(/"\z/, "")
    # Collapse whitespace immediately inside [ … ] and { … } pairs.
    s = s.gsub(/\[\s+/, "[").gsub(/\s+\]/, "]")
         .gsub(/\{\s+/, "{").gsub(/\s+\}/, "}")
    # Normalize trailing zeros on floats (`0.90` vs `0.9`): if the
    # value parses as a float, reformat via Ruby's Float#to_s.
    if s.match?(/\A-?\d+\.\d+\z/) && (f = Float(s, exception: false))
      s = f.to_s
    end
    # Ruby's nil.to_s is "", Rust keeps the source token "nil".
    s = "" if s == "nil"
    s
  }.transform_keys(&:to_s).sort.to_h
end

def ruby_ir(path)
  Hecks.instance_variable_set(:@last_fixtures_file, nil)
  Kernel.load(path)
  ff = Hecks.last_fixtures_file
  return nil unless ff
  fixtures = ff.fixtures.map do |fix|
    {
      "aggregate" => fix.aggregate_name.to_s,
      "name"      => fix.name.to_s,
      "attrs"     => normalize_attrs(fix.attributes),
    }
  end
  { "domain" => ff.name.to_s, "fixtures" => fixtures }
end

def rust_ir(path)
  out, _err, _st = Open3.capture3(HECKS_LIFE, "dump-fixtures", path)
  return nil if out.strip.empty?
  parsed = JSON.parse(out)
  fixtures = parsed["fixtures"].map do |f|
    {
      "aggregate" => f["aggregate"].to_s,
      "name"      => f["name"].to_s,
      "attrs"     => normalize_attrs(f["attrs"] || {}),
    }
  end
  { "domain" => parsed["domain"].to_s, "fixtures" => fixtures }
end

if ARGV.empty?
  files = Dir.glob("hecks_conception/**/*.fixtures") +
          Dir.glob("spec/parity/fixtures/**/*.fixtures")
else
  files = Dir.glob(ARGV[0])
end
abort "no .fixtures files matched" if files.empty?

# Known-drift list: paths where ruby/rust parse differently for known
# edge cases (typically embedded escape sequences in attribute values).
# Tracked rather than blocking so the contract still surfaces NEW drift.
KNOWN_DRIFT_FILE = File.expand_path("fixtures_known_drift.txt", __dir__)
known_drift = File.exist?(KNOWN_DRIFT_FILE) ?
  File.readlines(KNOWN_DRIFT_FILE).map(&:strip).reject { |l| l.empty? || l.start_with?("#") } : []

drift = 0
expected_drift = 0
agreed = 0
files.sort.each do |f|
  ruby = ruby_ir(f) rescue nil
  rust = rust_ir(f) rescue nil
  if ruby == rust && !ruby.nil?
    puts "✓ #{f}  (#{ruby["fixtures"].size} fixtures)"
    agreed += 1
  elsif known_drift.include?(f)
    puts "⚠ #{f}  (known drift)"
    expected_drift += 1
  else
    puts "✗ #{f}"
    puts "    ruby: #{ruby.inspect[0..200]}"
    puts "    rust: #{rust.inspect[0..200]}"
    drift += 1
  end
end

puts
puts "#{agreed}/#{files.size} parity (+ #{expected_drift} known drift)"
exit(drift.zero? ? 0 : 1)
