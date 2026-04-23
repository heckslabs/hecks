#!/usr/bin/env ruby
# features_audit.rb — cross-reference FEATURES.md claims against
# the codebase to distinguish verified features from aspirational ones.
#
# For each bullet in FEATURES.md:
#   1. extract code-like identifiers (PascalCase, backticked tokens,
#      Hecks::Namespaced names)
#   2. grep lib/, hecks_life/src/, hecks_conception/aggregates/**,
#      hecks_conception/capabilities/**, and spec/ for evidence
#   3. classify: verified | missing | unverifiable
#
# Usage:
#   ruby tools/features_audit.rb              # summary report
#   ruby tools/features_audit.rb --missing    # list missing claims
#   ruby tools/features_audit.rb --section "Attributes"   # filter
#   ruby tools/features_audit.rb --json       # machine-readable
#
# "verified" = at least one extracted identifier found in a searched path.
# "missing"  = identifiers exist but none were found anywhere.
# "unverifiable" = no code-like identifiers to grep on (pure prose).

require "json"
require "optparse"
require "open3"
require "pathname"
require "set"

REPO = Pathname.new(File.expand_path("..", __dir__))
FEATURES = REPO / "FEATURES.md"

# Paths searched for evidence. Order matters only for reporting.
SEARCH_PATHS = [
  ["ruby", REPO / "lib"],
  ["rust", REPO / "hecks_life" / "src"],
  ["bluebook_aggregates", REPO / "hecks_conception" / "aggregates"],
  ["bluebook_capabilities", REPO / "hecks_conception" / "capabilities"],
  ["tests", REPO / "spec"],
  ["examples", REPO / "examples"],
  ["bin", REPO / "bin"],
  ["claude_config", REPO / ".claude"],
].freeze

# Token shapes we strip before classifying — these aren't claims about
# implemented APIs, they're prose artifacts:
#   - <placeholder>.<method>  (Some*.foo, handle.build, OrdersDomain.x)
#   - <file>.md                (doc cross-references)
#   - model.<predicate>?       (generated predicate example)
PLACEHOLDER_PREFIXES = [
  "Some", "My", "handle.", "model.", "Orders", "TheModel"
].freeze

# Token extraction patterns. We only trust tokens with enough shape to
# grep usefully — short English words would match everything.
BACKTICKED = /`([^`\n]{2,120})`/
PASCAL = /\b([A-Z][a-z]+(?:[A-Z][a-z]+){1,})\b/          # e.g. CreatePizza
NAMESPACED = /\b([A-Z]\w*(?:::[A-Z]\w*)+)\b/             # Hecks::Chapters::Bootstrap
DOTTED = /\b([A-Za-z_]\w+(?:\.\w+){1,})\b/               # Hecks.domain, Kernel.load
SYMBOL = /:([a-z_][a-z0-9_]{2,})\b/                      # :status, :integer
# Inside backticks we also allow DSL keywords like `emits`, `list_of`,
# `reference_to`, `sets`, `lifecycle`, `saga`, `service` — single-word
# tokens that would be too noisy outside a code context.

# Prose tokens we refuse to search for (too noisy — match anywhere).
STOPWORDS = Set.new(%w[
  string integer float boolean date datetime json
  name type value block test spec file line
  true false none some all any each every
  one two three first last next new
  id ids uuid key keys field fields
])

def extract_backticked(text)
  # Inside-backtick tokens are trusted even if single-word —
  # `emits`, `reference_to`, etc.
  out = []
  text.scan(BACKTICKED) do |m|
    body = m[0].strip
    # Prefer the first "identifier-like" chunk; split on spaces, parens,
    # braces. Take tokens of length >= 3, reject stopwords.
    body.split(/[\s(){}\[\]"',]+/).each do |chunk|
      chunk = chunk.gsub(/\A[.:=>]+|[.:=>]+\z/, "")
      next if chunk.empty? || STOPWORDS.include?(chunk.downcase)
      # allow :symbol, Word, snake_case_word, Name.Thing, Name::Thing
      if chunk =~ /\A[A-Za-z_:][\w:.!?]*\z/ && chunk.length >= 3
        out << chunk
      end
    end
  end
  out
end

def extract_outside_backticks(text)
  # Only trust shapes strong enough to not match English:
  # PascalCase (2+ humps), dotted, namespaced, :symbol (len>=3).
  out = []
  text.scan(PASCAL) { |m| out << m[0] }
  text.scan(NAMESPACED) { |m| out << m[0] }
  text.scan(DOTTED) { |m| out << m[0] if m[0].include?(".") }
  text.scan(SYMBOL) { |m| out << ":" + m[0] }
  out
end

def placeholder?(token)
  # True for tokens that are prose artifacts, not code claims.
  return true if token.end_with?(".md")
  PLACEHOLDER_PREFIXES.each do |p|
    return true if token.start_with?(p) && token.include?(".")
  end
  # model.<predicate>? is a generated-predicate example.
  return true if token =~ /\Amodel\.\w+\?\z/
  false
end

def extract_identifiers(claim)
  # Return a list of greppable identifiers, deduped, ordered.
  # Remove backticked bodies from outside-check to avoid double-count.
  bt_tokens = extract_backticked(claim)
  outside = claim.gsub(BACKTICKED, " ")
  plain_tokens = extract_outside_backticks(outside)
  seen = {}
  ordered = []
  (bt_tokens + plain_tokens).each do |t|
    next if seen[t] || placeholder?(t)
    seen[t] = true
    ordered << t
  end
  ordered
end

def parse_features(path)
  # Parse FEATURES.md into a list of {section, subsection, line, text}.
  claims = []
  section = ""
  subsection = ""
  in_banner = false
  File.read(path).split("\n").each_with_index do |raw, idx|
    i = idx + 1
    line = raw.sub(/\s+\z/, "")
    if line.start_with?("> ")
      in_banner = true
      next
    end
    if in_banner && !line.start_with?(">")
      in_banner = false
    end
    if line.start_with?("## ")
      section = line[3..].strip
      subsection = ""
      next
    end
    if line.start_with?("### ")
      subsection = line[4..].strip
      next
    end
    # bullet
    m = line.match(/\A[-*]\s+(.*)\z/)
    next unless m
    claims << {
      "line" => i,
      "section" => section,
      "subsection" => subsection,
      "text" => m[1].strip
    }
  end
  claims
end

def rg_count(pattern, path, fixed: true)
  # Run rg and return count of matching files. 0 on any error.
  flags = ["--no-messages", "-l"]
  flags << "-F" if fixed
  begin
    stdout, _stderr, _status = Open3.capture3("rg", *flags, pattern, path.to_s)
    stdout.split("\n").count { |x| !x.strip.empty? }
  rescue Errno::ENOENT, StandardError
    0
  end
end

def search_token(token, search_paths)
  # Return dict of category → int count of matching files.
  #
  # For `Foo.bar` tokens, also check `def self.bar` and `def bar` under
  # any path that also mentions `Foo` — catches class-method conventions
  # where the literal `Foo.bar` never appears in the source.
  hits = {}
  # Split <head>.<method> tokens for a method-def fallback.
  method_def_self = nil
  method_def_inst = nil
  class_head = nil
  if (m = token.match(/\A([A-Za-z_][\w:]*)\.([a-z_]\w*)\z/))
    class_head = m[1]
    method_name = m[2]
    method_def_self = "def self.#{method_name}"
    method_def_inst = "def #{method_name}"
  end

  SEARCH_PATHS.each do |label, p|
    unless p.exist?
      hits[label] = 0
      next
    end
    n = rg_count(token, p, fixed: true)
    if n == 0 && method_def_self
      # PascalCase head → class method. Only count if the class
      # name also appears in the tree. Lowercase head → instance
      # method on whatever; count the def itself.
      if class_head[0] == class_head[0].upcase && class_head[0] =~ /[A-Z]/
        if rg_count(class_head, p, fixed: true) > 0
          n = rg_count(method_def_self, p, fixed: true)
        end
      else
        n = rg_count(method_def_inst, p, fixed: true)
      end
    end
    hits[label] = n
  end
  hits
end

def classify(claim, tokens, hits_by_token)
  return "unverifiable" if tokens.empty?
  # Verified if any token has at least one hit anywhere.
  tokens.each do |t|
    counts = hits_by_token[t] || {}
    return "verified" if counts.values.any? { |c| c > 0 }
  end
  "missing"
end

def run_audit(claims)
  results = []
  claims.each do |c|
    tokens = extract_identifiers(c["text"])
    hits = {}
    tokens.each { |t| hits[t] = search_token(t, SEARCH_PATHS) }
    verdict = classify(c, tokens, hits)
    results << c.merge("tokens" => tokens, "hits" => hits, "verdict" => verdict)
  end
  results
end

def print_summary(results)
  by_verdict = { "verified" => 0, "missing" => 0, "unverifiable" => 0 }
  results.each { |r| by_verdict[r["verdict"]] += 1 }
  total = results.length
  puts
  puts "FEATURES.md audit — #{total} claims"
  puts
  by_verdict.each do |v, n|
    pct = total > 0 ? (100.0 * n / total) : 0
    puts format("  %-13s %4d  (%5.1f%%)", v, n, pct)
  end
  puts
  puts "By section:"
  sections = {}
  sections_order = []
  results.each do |r|
    key = r["section"].dup
    key += " / #{r['subsection']}" unless r["subsection"].empty?
    unless sections.key?(key)
      sections[key] = { "v" => 0, "m" => 0, "u" => 0 }
      sections_order << key
    end
    k = { "verified" => "v", "missing" => "m", "unverifiable" => "u" }[r["verdict"]]
    sections[key][k] += 1
  end
  sections_order.each do |name|
    c = sections[name]
    total_s = c.values.sum
    puts "  #{name}  — v #{c['v']}, m #{c['m']}, u #{c['u']}  (#{total_s})"
  end
end

def print_missing(results, limit: nil)
  missing = results.select { |r| r["verdict"] == "missing" }
  puts
  puts "Missing — #{missing.length} claims with identifiers but no codebase hits:"
  puts
  slice = limit ? missing.first(limit) : missing
  slice.each do |r|
    sec = r["section"].dup
    sec += " / #{r['subsection']}" unless r["subsection"].empty?
    puts "  L#{r['line']}  [#{sec}]"
    text = r["text"]
    truncated = text.length > 110 ? text[0, 110] + "…" : text
    puts "    #{truncated}"
    puts "    searched: #{r['tokens'].join(', ')}"
    puts
  end
end

def main
  options = { missing: false, unverifiable: false, section: nil, limit: nil, json: false }
  OptionParser.new do |opts|
    opts.on("--missing", "list missing claims") { options[:missing] = true }
    opts.on("--unverifiable", "list unverifiable claims") { options[:unverifiable] = true }
    opts.on("--section SECTION", "filter to sections matching this substring") { |v| options[:section] = v }
    opts.on("--limit N", Integer, "cap listing output") { |v| options[:limit] = v }
    opts.on("--json", "machine-readable output") { options[:json] = true }
  end.parse!

  claims = parse_features(FEATURES)
  if options[:section]
    s = options[:section].downcase
    claims = claims.select { |c| c["section"].downcase.include?(s) || c["subsection"].downcase.include?(s) }
  end

  warn "auditing #{claims.length} claims against #{SEARCH_PATHS.length} source trees…"
  results = run_audit(claims)

  if options[:json]
    # Match Python's json.dumps(indent=2) defaults: 2-space indent, ASCII-safe
    # (escape non-ASCII as \uXXXX), space after ": " and ",".
    puts JSON.generate(
      results,
      indent: "  ",
      space: " ",
      object_nl: "\n",
      array_nl: "\n",
      ascii_only: true
    )
    return
  end

  print_summary(results)
  if options[:missing]
    print_missing(results, limit: options[:limit])
  end
  if options[:unverifiable]
    unv = results.select { |r| r["verdict"] == "unverifiable" }
    puts
    puts "Unverifiable — #{unv.length} claims (no code-like identifiers):"
    puts
    slice = options[:limit] ? unv.first(options[:limit]) : unv
    slice.each do |r|
      sec = r["section"].dup
      sec += " / #{r['subsection']}" unless r["subsection"].empty?
      text = r["text"]
      truncated = text.length > 100 ? text[0, 100] : text
      puts "  L#{r['line']}  [#{sec}]  #{truncated}"
    end
  end
end

main if __FILE__ == $PROGRAM_NAME
