# Winter::Conceive — fast domain creation from corpus patterns
#
# Uses structural vectors from all nursery + catalog domains to find
# the nearest archetype, then generates a new domain by mapping
# vocabulary through an anticorruption layer.
#
# Usage:
#   ruby conceive.rb "Geology" "The study of earth materials, processes, and history"
#   ruby conceive.rb "Accounting" "Financial transactions, ledgers, and reporting"
#
# The more domains in the corpus, the faster and better this gets.

require_relative "heki"

NURSERY = File.expand_path("nursery", __dir__)
CATALOG = File.expand_path("catalog", __dir__)
VERSION = "2026.04.11.1"

# ============================================================
# VECTOR EXTRACTION — structural fingerprint of a domain
# ============================================================

def extract_vector(path)
  content = File.read(path)
  aggs = content.scan(/^\s*aggregate\s+"(\w+)"/).size
  cmds = content.scan(/^\s*command\s+"(\w+)"/).size
  policies = content.scan(/^\s*policy\s+"(\w+)"/).size
  vos = content.scan(/^\s*value_object\s+"(\w+)"/).size
  lifecycles = content.scan(/^\s*lifecycle\s+/).size
  refs = content.scan(/^\s*reference_to\s+/).size
  lists = content.scan(/list_of\(/).size
  givens = content.scan(/^\s*given\s+/).size
  fixtures = content.scan(/^\s*fixture\s+"/).size
  lines = content.lines.size

  {
    name: content[/Hecks\.bluebook\s+"(\w+)"/, 1] || File.basename(path, ".bluebook"),
    path: path,
    vec: [aggs, cmds.to_f / [aggs, 1].max, vos, policies, refs, lifecycles, lists, givens, fixtures],
    stats: { aggs: aggs, cmds: cmds, vos: vos, policies: policies, lines: lines }
  }
end

# ============================================================
# CORPUS — load all domains from nursery + catalog
# ============================================================

def load_corpus
  domains = []
  [NURSERY, CATALOG].each do |dir|
    Dir.glob(File.join(dir, "**/*.bluebook")).each do |path|
      next if File.basename(path) == "catalog.bluebook"
      domains << extract_vector(path)
    end
  end
  domains
end

# ============================================================
# SIMILARITY — cosine distance between vectors
# ============================================================

def cosine(a, b)
  dot = a.zip(b).sum { |x, y| x * y }
  mag_a = Math.sqrt(a.sum { |x| x**2 })
  mag_b = Math.sqrt(b.sum { |x| x**2 })
  return 0.0 if mag_a == 0 || mag_b == 0
  dot / (mag_a * mag_b)
end

def nearest(target_vec, corpus, k: 5)
  corpus
    .map { |d| d.merge(sim: cosine(target_vec, d[:vec])) }
    .sort_by { |d| -d[:sim] }
    .first(k)
end

# ============================================================
# SEED VECTOR — estimate shape from description keywords
# ============================================================

SHAPE_HINTS = {
  "lifecycle"    => [3, 3, 1, 2, 1, 2, 1, 1, 0],
  "pipeline"     => [4, 4, 2, 3, 2, 2, 1, 1, 0],
  "governance"   => [5, 5, 3, 4, 2, 3, 1, 2, 2],
  "science"      => [4, 5, 2, 3, 1, 1, 1, 1, 3],
  "biology"      => [4, 6, 2, 3, 1, 2, 1, 1, 3],
  "chemistry"    => [4, 4, 2, 2, 1, 1, 1, 1, 3],
  "physics"      => [4, 5, 1, 3, 1, 2, 1, 1, 2],
  "math"         => [5, 5, 1, 3, 0, 1, 1, 0, 2],
  "finance"      => [4, 4, 2, 3, 2, 2, 2, 2, 1],
  "manufacturing"=> [5, 5, 3, 4, 2, 3, 2, 2, 2],
  "compliance"   => [4, 4, 2, 4, 2, 3, 1, 2, 2],
  "tracking"     => [4, 3, 1, 2, 2, 2, 1, 0, 1],
  "simple"       => [2, 2, 1, 1, 0, 0, 1, 0, 0],
  "complex"      => [6, 5, 3, 4, 3, 3, 2, 2, 2],
}

def seed_vector(description)
  base = [3, 3.5, 1, 2, 1, 1, 1, 1, 1]
  words = description.downcase.split(/\W+/)
  matched = words.select { |w| SHAPE_HINTS.key?(w) }
  return base if matched.empty?

  hint_vecs = matched.map { |w| SHAPE_HINTS[w] }
  base.each_index.map { |i|
    (base[i] + hint_vecs.sum { |v| v[i] }) / (1 + hint_vecs.size).to_f
  }
end

# ============================================================
# GENERATE — build a bluebook from the nearest archetype
# ============================================================

def extract_aggregate_shapes(path)
  content = File.read(path)
  shapes = []

  content.scan(/aggregate\s+"(\w+)"(?:,\s*"([^"]*)")?\s+do(.*?)(?=\n  aggregate|\n  #.*===|\n  policy|\n  fixture|\nend)/m) do |name, desc, body|
    attrs = body.scan(/attribute\s+:(\w+)(?:,\s*(\w+))?/).map { |n, t| { name: n, type: t || "String" } }
    cmds = body.scan(/command\s+"(\w+)"/).flatten
    vos = body.scan(/value_object\s+"(\w+)"/).flatten
    has_lifecycle = body.include?("lifecycle")
    shapes << { name: name, desc: desc, attrs: attrs, cmds: cmds, vos: vos, lifecycle: has_lifecycle }
  end
  shapes
end

def generate_bluebook(name, vision, archetype_path)
  shapes = extract_aggregate_shapes(archetype_path)
  archetype_name = File.read(archetype_path)[/Hecks\.bluebook\s+"(\w+)"/, 1]

  lines = ["Hecks.bluebook \"#{name}\", version: \"#{VERSION}\" do"]
  lines << "  vision \"#{vision}\""
  lines << ""

  shapes.each do |shape|
    lines << "  aggregate \"#{shape[:name]}\", \"#{shape[:desc] || "A #{shape[:name].downcase} in the #{name} domain"}\" do"
    shape[:attrs].each do |a|
      type = a[:type] == "String" ? "" : ", #{a[:type]}"
      lines << "    attribute :#{a[:name]}#{type}"
    end
    shape[:vos].each { |vo| lines << "    # value_object \"#{vo}\" — fill in" }
    shape[:cmds].each do |cmd|
      lines << ""
      lines << "    command \"#{cmd}\" do"
      lines << "      role \"User\""
      lines << "      description \"TODO\""
      lines << "      emits \"#{cmd.sub(/^[A-Z][a-z]+/, '')}#{cmd.scan(/^[A-Z][a-z]+/).first}ed\""
      lines << "    end"
    end
    if shape[:lifecycle]
      lines << ""
      lines << "    # lifecycle :status — fill in transitions"
    end
    lines << "  end"
    lines << ""
  end

  lines << "end"
  lines.join("\n") + "\n"
end

# ============================================================
# MAIN
# ============================================================

if __FILE__ == $PROGRAM_NAME

name = ARGV[0]
vision = ARGV[1] || "A #{name} domain"

unless name
  puts "Usage: ruby conceive.rb \"Name\" \"Vision description\""
  exit 1
end

puts "Loading corpus..."
corpus = load_corpus
puts "  #{corpus.size} domains, #{corpus.sum { |d| d[:stats][:aggs] }} aggregates"
puts ""

seed = seed_vector(vision)
puts "Seed vector: #{seed.map { |x| x.round(1) }}"
top = nearest(seed, corpus, k: 5)

puts "Nearest domains:"
top.each do |d|
  puts "  %5.1f%%  %-25s %s" % [d[:sim] * 100, d[:name], d[:vec].map { |x| x.is_a?(Float) ? x.round(1) : x }.inspect]
end
puts ""

archetype = top.first
puts "Using archetype: #{archetype[:name]} (#{(archetype[:sim] * 100).round(1)}% similar)"
puts ""

# Generate
slug = name.gsub(/([A-Z])/, '_\1').downcase.sub(/^_/, '')
out_dir = File.join(NURSERY, slug)
Dir.mkdir(out_dir) unless File.directory?(out_dir)
out_path = File.join(out_dir, "#{slug}.bluebook")

bluebook = generate_bluebook(name, vision, archetype[:path])
File.write(out_path, bluebook)

aggs = bluebook.scan(/aggregate/).size
cmds = bluebook.scan(/command/).size
puts "Generated: #{out_path}"
puts "  #{aggs} aggregates, #{cmds} commands (scaffold from #{archetype[:name]})"
puts ""
puts "Next: edit #{out_path} to fill in domain-specific vocabulary"
