# seed_nursery_census.rb — Indexes all nursery domains into Winter's brain
# Scans every .bluebook in nursery/, extracts metadata, classifies by sector,
# writes domain_entry JSON + .heki files, updates nursery_awareness.heki
#
# Usage: ruby seed_nursery_census.rb

require "json"
require "securerandom"
require "zlib"
require "time"

NURSERY = File.expand_path("hecks_conception/nursery", __dir__)
INFO    = File.expand_path("hecks_being/winter/information", __dir__)
ENTRY_DIR = File.join(INFO, "domain_entry")

SECTOR_KEYWORDS = {
  "manufacturing" => %w[manufacturing factory foundry mill forge furnace welding casting assembly fabrication machining stamping molding extrusion smelting refinery distillery brewery winery bottling canning packaging],
  "healthcare" => %w[hospital clinic medical surgical pharmacy dental nursing patient therapy rehabilitation prosthetic diagnostic laboratory pathology oncology cardiology neurology pediatric obstetric psychiatric ambulance emergency triage],
  "agriculture" => %w[farm agriculture crop livestock poultry dairy aquaculture horticulture vineyard orchard greenhouse nursery seed irrigation harvest grain],
  "food_service" => %w[restaurant catering pizza bakery kitchen menu chef food meal recipe cooking dining cafe bistro],
  "logistics" => %w[logistics shipping freight cargo warehouse distribution fleet trucking port harbor dock terminal container],
  "finance" => %w[bank banking insurance mortgage lending credit loan investment portfolio trading brokerage hedge fund actuarial accounting audit tax],
  "education" => %w[school university college academy training curriculum student teacher professor classroom lecture exam grade scholarship],
  "technology" => %w[software data_center cloud hosting network cyber security satellite telecommunications fiber_optic],
  "construction" => %w[construction building architecture roofing plumbing electrical hvac concrete masonry excavation demolition scaffolding],
  "energy" => %w[energy solar wind nuclear power grid turbine generator battery renewable petroleum natural_gas coal],
  "transportation" => %w[airline airport aviation railroad railway transit bus taxi ride ferry cruise ship vehicle car auto],
  "retail" => %w[retail store shop boutique mall ecommerce marketplace auction inventory merchandise],
  "government" => %w[government municipal courthouse prison jail immigration customs border passport visa census election voting],
  "military" => %w[military army navy air_force marine base defense weapon ammunition],
  "entertainment" => %w[theater cinema concert festival museum gallery amusement theme_park casino gaming],
  "sports" => %w[sports stadium arena gym fitness athletic swimming pool tennis golf boxing wrestling martial],
  "real_estate" => %w[real_estate property apartment condo rental lease mortgage housing],
  "mining" => %w[mining quarry mineral ore excavation drilling],
  "environment" => %w[environmental conservation wildlife ecosystem recycling waste pollution climate weather],
  "legal" => %w[legal law attorney court arbitration mediation contract patent trademark copyright],
  "media" => %w[media news broadcast radio television podcast publishing magazine newspaper],
  "hospitality" => %w[hotel motel resort spa lodge inn hostel accommodation booking reservation],
  "science" => %w[laboratory research observatory telescope microscope chemistry physics biology genetics genomic],
  "maritime" => %w[maritime marine ocean ship vessel submarine anchor buoy lighthouse],
  "religious" => %w[church temple mosque synagogue monastery seminary religious worship],
  "veterinary" => %w[veterinary animal pet kennel zoo aquarium wildlife],
  "textile" => %w[textile fabric clothing apparel fashion garment sewing weaving dyeing],
  "chemical" => %w[chemical pharmaceutical cosmetic paint adhesive polymer plastic rubber],
  "automotive" => %w[automotive car vehicle engine transmission brake tire wheel dealership],
  "aerospace" => %w[aerospace rocket satellite space launch orbit propulsion],
  "telecom" => %w[telecom telephone mobile cellular wireless broadband fiber cable],
}

def classify_sector(domain_name)
  name_words = domain_name.split("_")

  SECTOR_KEYWORDS.each do |sector, keywords|
    keywords.each do |kw|
      return sector if name_words.any? { |w| w.include?(kw) || kw.include?(w) }
    end
  end

  "general"
end

def parse_bluebook(path)
  content = File.read(path)

  name_match = content.match(/Hecks\.bluebook\s+"([^"]+)"/)
  domain_name = name_match ? name_match[1] : File.basename(File.dirname(path)).split("_").map(&:capitalize).join

  version_match = content.match(/version:\s+"([^"]+)"/)
  version = version_match ? version_match[1] : nil

  vision_match = content.match(/vision\s+"([^"]+)"/)
  vision = vision_match ? vision_match[1] : nil

  aggregates = []
  content.scan(/aggregate\s+"(\w+)"/) do |m|
    agg_name = m[0]
    aggregates << agg_name
  end

  command_count = content.scan(/command\s+"/).size
  policy_count = content.scan(/policy\s+"/).size
  event_count = content.scan(/emits\s+"/).size
  lifecycle_count = content.scan(/lifecycle\s+:/).size
  line_count = content.lines.size

  {
    domain_name: domain_name,
    version: version,
    vision: vision,
    aggregates: aggregates,
    aggregate_count: aggregates.size,
    command_count: command_count,
    policy_count: policy_count,
    event_count: event_count,
    lifecycle_count: lifecycle_count,
    line_count: line_count,
    path: path.sub(File.expand_path("..", NURSERY) + "/", "")
  }
end

def write_heki(name, records)
  path = File.join(INFO, "#{name}.heki")
  blob = Zlib::Deflate.deflate(Marshal.dump(records))
  File.binwrite(path, "HEKI" + [1].pack("V") + blob)
  puts "  wrote #{path} (#{records.size} records)"
end

# --- Main ---

puts "Scanning nursery at #{NURSERY}..."
dirs = Dir.children(NURSERY).select { |d| File.directory?(File.join(NURSERY, d)) }.sort
puts "Found #{dirs.size} domain directories"

# Load existing entries to preserve IDs
existing = {}
if File.directory?(ENTRY_DIR)
  Dir.glob(File.join(ENTRY_DIR, "*.json")).each do |f|
    data = JSON.parse(File.read(f))
    existing[data["domain_name"]] = data
  end
end
puts "Existing entries: #{existing.size}"

# Parse all domains
now = Time.now.iso8601
entries = {}
sectors = Hash.new { |h, k| h[k] = [] }
cross_refs = {}
errors = []

dirs.each do |dir|
  bluebooks = Dir.glob(File.join(NURSERY, dir, "*.bluebook"))

  if bluebooks.empty?
    errors << { dir: dir, reason: "empty" }
    next
  end

  bluebooks.each do |bluebook|
  begin
    parsed = parse_bluebook(bluebook)
    sector = classify_sector(File.basename(bluebook, ".bluebook"))

    # Reuse existing ID or create new
    id = existing.dig(parsed[:domain_name], "id") || SecureRandom.uuid

    entry = {
      "id" => id,
      "domain_name" => parsed[:domain_name],
      "directory" => dir,
      "version" => parsed[:version],
      "vision" => parsed[:vision],
      "path" => parsed[:path],
      "line_count" => parsed[:line_count],
      "aggregate_count" => parsed[:aggregate_count],
      "command_count" => parsed[:command_count],
      "policy_count" => parsed[:policy_count],
      "event_count" => parsed[:event_count],
      "lifecycle_count" => parsed[:lifecycle_count],
      "aggregate_names" => parsed[:aggregates],
      "sector" => sector,
      "tags" => [sector],
      "created_at" => existing.dig(parsed[:domain_name], "created_at") || now,
      "updated_at" => now
    }

    entries[id] = entry
    sectors[sector] << { "domain_name" => parsed[:domain_name], "id" => id }

    # Track cross-references from aggregate names
    parsed[:aggregates].each do |agg|
      cross_refs[agg] ||= []
      cross_refs[agg] << parsed[:domain_name]
    end
  rescue => e
    errors << { dir: dir, reason: e.message }
  end
  end # bluebooks.each
end

empty_count = errors.count { |e| e.is_a?(Hash) && e[:reason] == "empty" }
parse_errors = errors.reject { |e| e.is_a?(Hash) && e[:reason] == "empty" }
puts "\nParsed #{entries.size} domains, #{empty_count} empty dirs, #{parse_errors.size} parse errors"
parse_errors.first(5).each { |e| puts "  ERROR: #{e}" } if parse_errors.any?

# Write domain_entry JSON files
FileUtils.mkdir_p(ENTRY_DIR)
entries.each do |id, entry|
  File.write(File.join(ENTRY_DIR, "#{id}.json"), JSON.pretty_generate(entry))
end
puts "\nWrote #{entries.size} domain_entry JSON files"

# Build .heki files
puts "\nBuilding .heki files..."

# 1. domain_entry.heki
write_heki("domain_entry", entries)

# 2. sector.heki
sector_records = {}
sectors.each do |name, members|
  id = SecureRandom.uuid
  sector_records[id] = {
    "id" => id,
    "name" => name,
    "domain_count" => members.size,
    "domains" => members,
    "created_at" => now,
    "updated_at" => now
  }
end
write_heki("sector", sector_records)

# 3. cross_reference.heki — aggregates shared across domains
shared_aggs = cross_refs.select { |_, domains| domains.size > 1 }
xref_records = {}
shared_aggs.each do |agg_name, domains|
  id = SecureRandom.uuid
  xref_records[id] = {
    "id" => id,
    "aggregate_name" => agg_name,
    "domains" => domains.uniq,
    "domain_count" => domains.uniq.size,
    "created_at" => now,
    "updated_at" => now
  }
end
write_heki("cross_reference", xref_records)

# 4. census.heki — the master snapshot
census_id = SecureRandom.uuid
total_aggs = entries.values.sum { |e| e["aggregate_count"] }
total_cmds = entries.values.sum { |e| e["command_count"] }
total_policies = entries.values.sum { |e| e["policy_count"] }
total_events = entries.values.sum { |e| e["event_count"] }
total_lines = entries.values.sum { |e| e["line_count"] }

sector_breakdown = sectors.map { |name, members| { "sector" => name, "count" => members.size } }
  .sort_by { |s| -s["count"] }

census_records = {
  census_id => {
    "id" => census_id,
    "total_domains" => entries.size,
    "total_aggregates" => total_aggs,
    "total_commands" => total_cmds,
    "total_policies" => total_policies,
    "total_events" => total_events,
    "total_lines" => total_lines,
    "sector_count" => sectors.size,
    "sectors" => sector_breakdown,
    "cross_references" => shared_aggs.size,
    "errors" => errors.size,
    "taken_at" => now,
    "created_at" => now,
    "updated_at" => now
  }
}
write_heki("census", census_records)

# 5. Update nursery_awareness.heki
awareness_id = SecureRandom.uuid
awareness_records = {
  awareness_id => {
    "id" => awareness_id,
    "domain_count" => entries.size,
    "bluebook_count" => entries.size,
    "favorite_domains" => ["pizzas", "immune_system", "circulatory_system", "gene_regulation", "ecosystem", "supply_chain"],
    "last_conceived" => nil,
    "sectors" => sectors.keys.sort,
    "created_at" => now,
    "updated_at" => now
  }
}
write_heki("nursery_awareness", awareness_records)

# Summary
puts "\n=== NURSERY CENSUS COMPLETE ==="
puts "Domains indexed:     #{entries.size}"
puts "Sectors identified:  #{sectors.size}"
puts "Cross-references:    #{shared_aggs.size}"
puts "Total aggregates:    #{total_aggs}"
puts "Total commands:      #{total_cmds}"
puts "Total policies:      #{total_policies}"
puts "Total events:        #{total_events}"
puts "Total lines:         #{total_lines}"
puts ""
puts "Top sectors:"
sector_breakdown.first(15).each do |s|
  puts "  %-25s %d" % [s["sector"], s["count"]]
end
puts ""
puts "Top shared aggregates:"
shared_aggs.sort_by { |_, d| -d.uniq.size }.first(10).each do |agg, domains|
  puts "  %-25s shared by %d domains" % [agg, domains.uniq.size]
end
