# index_nursery.rb
# Scans every bluebook in the nursery and persists DomainEntry records
# as JSON in hecks_being/winter/information/domain_entry/
#
# Usage: ruby -Ilib hecks_conception/index_nursery.rb

require 'hecks'
require 'json'
require 'securerandom'
require 'time'

NURSERY = File.expand_path("nursery", __dir__)
INFO_DIR = File.expand_path("../hecks_being/winter/information", __dir__)

BIOLOGY_KEYWORDS  = %w[cell organ tissue blood immune nerve gut muscle bone wound pulse gene protein].freeze
CHEMISTRY_KEYWORDS = %w[reaction catalyst enzyme polymer crystal acid base electro thermo spectro ferment combustion].freeze
BUSINESS_KEYWORDS  = %w[order invoice payment claim filing permit booking reservation delivery exchange trading].freeze
SOCIAL_KEYWORDS    = %w[adoption volunteer election governance immigration prison court genealogy].freeze

def tag_domain(name)
  lower = name.downcase
  tags = []
  tags << "biology"  if BIOLOGY_KEYWORDS.any?  { |k| lower.include?(k) }
  tags << "chemistry" if CHEMISTRY_KEYWORDS.any? { |k| lower.include?(k) }
  tags << "business"  if BUSINESS_KEYWORDS.any?  { |k| lower.include?(k) }
  tags << "social"    if SOCIAL_KEYWORDS.any?    { |k| lower.include?(k) }
  tags << "general"   if tags.empty?
  tags
end

def parse_bluebook(path)
  content = File.read(path)
  lines = content.lines

  domain_name = content[/Hecks\.bluebook\s+"(\w+)"/, 1] || File.basename(File.dirname(path))
  version = content[/version:\s+"([^"]+)"/, 1] || "unknown"

  aggregates = []
  current_agg = nil
  in_aggregate = false
  depth = 0

  lines.each do |line|
    stripped = line.strip

    if stripped.match?(/^\s*aggregate\s+"(\w+)"/) && depth <= 1
      name = stripped[/aggregate\s+"(\w+)"/, 1]
      current_agg = { name: name, command_count: 0, event_count: 0, has_lifecycle: false, references: [] }
      in_aggregate = true
    end

    if in_aggregate
      current_agg[:command_count] += 1 if stripped.match?(/^\s*command\s+"/)
      current_agg[:event_count] += 1 if stripped.match?(/emits\s+"/)
      current_agg[:has_lifecycle] = true if stripped.match?(/lifecycle\s+:/)
      if stripped.match?(/reference_to\s+(\w+)/)
        ref = stripped[/reference_to\s+(\w+)/, 1]
        current_agg[:references] << ref unless current_agg[:references].include?(ref)
      end
    end

    if stripped == "end" && in_aggregate
      depth_count = lines[0..lines.index(line)].count { |l| l.strip.match?(/\bdo\b\s*$/) }
      end_count = lines[0..lines.index(line)].count { |l| l.strip == "end" }
      if depth_count - end_count <= 0
        aggregates << current_agg if current_agg
        current_agg = nil
        in_aggregate = false
      end
    end
  end
  aggregates << current_agg if current_agg

  policy_count = content.scan(/policy\s+"/).size

  {
    domain_name: domain_name,
    version: version,
    path: path.sub(File.expand_path("../..", __dir__) + "/", ""),
    line_count: lines.size,
    aggregates: aggregates,
    policy_count: policy_count,
    tags: tag_domain(domain_name)
  }
end

# Scan all bluebooks
bluebooks = Dir.glob(File.join(NURSERY, "*/*.bluebook")).sort
entries = bluebooks.map { |path| parse_bluebook(path) }

# Persist DomainEntry records
entry_dir = File.join(INFO_DIR, "domain_entry")
FileUtils.mkdir_p(entry_dir)
# Clear old index
Dir.glob(File.join(entry_dir, "*.json")).each { |f| File.delete(f) }

entries.each do |entry|
  id = SecureRandom.uuid
  now = Time.now.iso8601
  record = {
    id: id,
    domain_name: entry[:domain_name],
    version: entry[:version],
    path: entry[:path],
    line_count: entry[:line_count],
    aggregates: entry[:aggregates],
    policy_count: entry[:policy_count],
    tags: entry[:tags],
    created_at: now,
    updated_at: now
  }
  File.write(File.join(entry_dir, "#{id}.json"), JSON.pretty_generate(record))
end

# Build cross-references from aggregate references
xref_dir = File.join(INFO_DIR, "cross_reference")
FileUtils.mkdir_p(xref_dir)
Dir.glob(File.join(xref_dir, "*.json")).each { |f| File.delete(f) }

# Build aggregate-to-domain lookup
agg_to_domain = {}
entries.each do |entry|
  entry[:aggregates].each { |a| agg_to_domain[a[:name]] = entry[:domain_name] }
end

# Detect cross-domain references (same-name aggregates across domains)
name_groups = entries.group_by { |e| e[:aggregates].map { |a| a[:name] } }.values
# Instead, find domains that share aggregate names
agg_names = {}
entries.each do |entry|
  entry[:aggregates].each do |a|
    (agg_names[a[:name]] ||= []) << entry[:domain_name]
  end
end

agg_names.select { |_, domains| domains.size > 1 }.each do |agg_name, domains|
  domains.combination(2).each do |src, tgt|
    id = SecureRandom.uuid
    now = Time.now.iso8601
    record = {
      id: id,
      source_domain: src,
      target_domain: tgt,
      relationship: "shared_concept",
      through: agg_name,
      created_at: now,
      updated_at: now
    }
    File.write(File.join(xref_dir, "#{id}.json"), JSON.pretty_generate(record))
  end
end

# Persist NurserySummary
summary_dir = File.join(INFO_DIR, "nursery_summary")
FileUtils.mkdir_p(summary_dir)
Dir.glob(File.join(summary_dir, "*.json")).each { |f| File.delete(f) }

total_aggs = entries.sum { |e| e[:aggregates].size }
total_cmds = entries.sum { |e| e[:aggregates].sum { |a| a[:command_count] } }
total_policies = entries.sum { |e| e[:policy_count] }
total_lines = entries.sum { |e| e[:line_count] }

tag_counts = entries.flat_map { |e| e[:tags] }
  .tally
  .map { |tag, count| { tag: tag, count: count } }
  .sort_by { |t| -t[:count] }

summary_id = SecureRandom.uuid
now = Time.now.iso8601
summary = {
  id: summary_id,
  total_domains: entries.size,
  total_aggregates: total_aggs,
  total_commands: total_cmds,
  total_policies: total_policies,
  total_lines: total_lines,
  indexed_at: now,
  tag_counts: tag_counts,
  created_at: now,
  updated_at: now
}
File.write(File.join(summary_dir, "#{summary_id}.json"), JSON.pretty_generate(summary))

# Report
puts "Indexed #{entries.size} domains"
puts "  #{total_aggs} aggregates, #{total_cmds} commands, #{total_policies} policies"
puts "  #{total_lines} total lines"
puts "  #{Dir.glob(File.join(xref_dir, '*.json')).size} cross-references"
puts "Tags: #{tag_counts.map { |t| "#{t[:tag]}(#{t[:count]})" }.join(', ')}"
