# Hecks::Parity::FixturesParityTest
#
# Runs every .fixtures file through the Ruby DSL builder
# (Hecks.fixtures → FixturesBuilder) and through the Rust parser
# (`storehouse dump <file>` — content-routed via fixtures_parser),
# then diffs the IRs. Drift is a hard contract failure.
#
# A .fixtures IR is a (domain_name, [Fixture]) pair. Each Fixture is
# an (aggregate_name, name?, attributes) tuple. The Ruby and Rust
# parsers produce structurally identical lists for any well-formed
# input — that's the contract this guards.
#
# Run: bundle exec ruby -Ilib parity/fixtures_parity_test.rb
#
require "open3"
require "json"

STOREHOUSE = File.expand_path("../rust/target/release/storehouse", __dir__)
abort "storehouse not built" unless File.executable?(STOREHOUSE)

require "hecks"
require "hecks/dsl/fixtures_builder"

def normalize_attrs(h)
  # Both runtimes serialize attribute values as the source token. Ruby's
  # builder keeps them in their native types (Integer, Float, String,
  # Array, Hash, etc.); the Rust parser keeps them as the verbatim
  # source string. To diff fairly we convert each Ruby value back to
  # its bluebook source form (mirrors canonical_ir's mutation_value
  # rules for hashes/arrays/symbols), then normalize whitespace and
  # quotes so the two representations agree byte-for-byte.
  h.transform_values { |v|
    # Convert structured Ruby objects (Hash, Array) back to bluebook
    # source form ; primitives pass through their .to_s.
    s = if v.is_a?(Hash) || v.is_a?(Array)
          to_bluebook_source(v)
        else
          v.to_s
        end
    s = s.sub(/\A"/, "").sub(/"\z/, "")
    # Collapse whitespace immediately inside [ … ] and { … } pairs
    # so `[ "a", "b" ]` (source-form) matches `["a", "b"]` (compact
    # form). Idempotent.
    s = s.gsub(/\[\s+/, "[").gsub(/\s+\]/, "]")
         .gsub(/\{\s+/, "{").gsub(/\s+\}/, "}")
    # Collapse runs of whitespace to single spaces OUTSIDE of quoted
    # strings — bluebook fixtures sometimes use multi-space alignment
    # (e.g. `name: "Re",    meaning: "again"`) which Rust preserves
    # verbatim ; Ruby parses to objects and re-stringifies with
    # single spaces. Walk char-by-char tracking quote state so the
    # whitespace inside `"two  spaces"` is left alone.
    out = String.new(capacity: s.length)
    in_str = false
    prev = "\0"
    last_was_space = false
    s.each_char do |c|
      if c == "\"" && prev != "\\"
        in_str = !in_str
        out << c
        last_was_space = false
      elsif !in_str && (c == " " || c == "\t")
        out << " " unless last_was_space
        last_was_space = true
      else
        out << c
        last_was_space = false
      end
      prev = c
    end
    s = out
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

# Convert a Ruby value back to its bluebook source form. Mirrors the
# rules in parity/canonical_ir.rb's mutation_value (Symbol → :sym,
# String → "...", Hash → { k: v, ... } with shorthand symbol keys,
# Array → [ ... ], primitives → to_s). Used to compare against
# Rust's source-preserving fixture parser without forcing Rust to
# reparse Ruby's `=>` inspect form.
def to_bluebook_source(v)
  case v
  when Symbol then ":#{v}"
  when String then "\"#{v}\""
  when Numeric, TrueClass, FalseClass then v.to_s
  when nil then "nil"
  when Hash
    inner = v.map { |k, val| "#{k}: #{to_bluebook_source(val)}" }.join(", ")
    "{ #{inner} }"
  when Array
    "[#{v.map { |e| to_bluebook_source(e) }.join(", ")}]"
  else v.to_s
  end
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
  out, _err, _st = Open3.capture3(STOREHOUSE, "dump-fixtures", path)
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
          Dir.glob("parity/fixtures/**/*.fixtures")
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
