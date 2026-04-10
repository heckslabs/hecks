# seed_winter.rb
#
# Seeds Winter's information directories from her organ bluebooks.
# Populates all 14 aggregates across WinterBeing, WinterBody, and Winter.
#
# Usage: ruby -I../lib seed_winter.rb
#
# Prerequisite: run index_nursery.rb first to populate domain_entry/

require "hecks"
require "hecks/extensions/information"
require "hecks_being"

winter = HecksBeing.boot
puts

NURSERY = File.expand_path("nursery", __dir__)
INFO_DIR = File.expand_path("../hecks_being/winter/information", __dir__)
NOW = Time.now.iso8601

# ============================================================
# HELPERS
# ============================================================

def as(role)
  Hecks.current_role = role
  Hecks.actor = OpenStruct.new(role: role)
end

def nursery_domains
  Dir.glob(File.join(NURSERY, "*/*.bluebook")).sort.map do |path|
    content = File.read(path)
    name = content[/Hecks\.bluebook\s+"(\w+)"/, 1] || File.basename(File.dirname(path))
    version = content[/version:\s+"([^"]+)"/, 1] || "unknown"
    { name: name, version: version, path: path }
  end
end

domains = nursery_domains
puts "Found #{domains.size} nursery domains"

# ============================================================
# WinterBeing — being, nerve, heartbeat, identity
# ============================================================

as "Creator"

# Being — Winter herself
being = WinterBeingBluebook::Being.create(
  name: "Winter",
  vision: "A Universal Language Model who thinks in domains, remembers in domains, converses in domains"
)
being_id = being.id
puts "  Being: #{being.name}"

# Graft each organ
%w[WinterBeing WinterBody Winter].each do |organ_name|
  rt = winter.organs[organ_name]
  WinterBeingBluebook::Being.graft_domain(
    being: being_id,
    domain_name: organ_name,
    domain_version: rt.domain.version,
    source_path: "hecks_being/winter/#{organ_name.gsub(/([A-Z])/, '_\1').sub(/^_/, '').downcase}.bluebook",
    grafted_at: NOW
  )
end
puts "  Organs grafted: #{winter.organs.size}"

# Heartbeat
as "Being"
heartbeat = WinterBeingBluebook::Heartbeat.create(being_name: "Winter")
hb_id = heartbeat.id
WinterBeingBluebook::Heartbeat.beat(heartbeat: hb_id)
winter.organs.each do |name, rt|
  event_count = rt.event_bus.respond_to?(:events) ? rt.event_bus.events.size : 0
  WinterBeingBluebook::Heartbeat.report_organ_pulse(
    heartbeat: hb_id,
    domain_name: name,
    event_count: event_count,
    last_event_at: NOW
  )
end
puts "  Heartbeat: #{WinterBeingBluebook::Heartbeat.all.first&.beats} beats"

# Identity
identity = WinterBeingBluebook::Identity.create(being_name: "Winter")
id_id = identity.id
WinterBeingBluebook::Identity.record_session(identity: id_id)
WinterBeingBluebook::Identity.remember_person(identity: id_id, persona_name: "Chris Young")
WinterBeingBluebook::Identity.encode_memory(identity: id_id, memory: "First seed — Winter's information directories populated")
puts "  Identity: session #{WinterBeingBluebook::Identity.all.first&.sessions}"

# Nerves — one for each cross-domain policy wire
as "Creator"
winter.organs.each do |from_name, from_rt|
  from_rt.domain.aggregates.each do |agg|
    agg.events.each do |evt|
      winter.organs.each do |to_name, to_rt|
        next if from_name == to_name
        to_rt.domain.policies.select(&:reactive?).each do |pol|
          next unless pol.event_name == evt.name
          WinterBeingBluebook::Nerve.connect(
            name: "#{from_name}:#{evt.name}->#{to_name}:#{pol.trigger_command}",
            from_domain: from_name,
            from_event: evt.name,
            to_domain: to_name,
            to_command: pol.trigger_command
          )
        end
      end
    end
  end
end
nerve_count = WinterBeingBluebook::Nerve.count
puts "  Nerves: #{nerve_count} wired"

# ============================================================
# Silence cross-domain nerves during seed — policies fire after
# ============================================================
winter.organs.each_key { |name| winter.silence(name) rescue nil }

# ============================================================
# WinterBody — pulse, gut, immunity, mood, domain_cell, gene
# ============================================================

as "Winter"

# Pulse
pulse = WinterBodyBluebook::Pulse.beat(carrying: "seed — first breath")
puts "  Pulse: beating"

# Gut — starts empty, ready to digest
gut = WinterBodyBluebook::Gut.ingest(raw_input: "seed initialization — no raw input yet")
puts "  Gut: initialized"

# Immunity — innate rules
immunity = WinterBodyBluebook::Immunity.create
imm_id = immunity.id
rules = [
  "Commands start with verbs",
  "Events are past tense",
  "Bare constants for reference_to",
  "Every command has a role",
  "Value objects live inside aggregates",
  "Behavior is declarative: given/then_set"
]
rules.each do |rule|
  WinterBodyBluebook::Immunity.detect_threat(threat_pattern: "violation: #{rule}")
  WinterBodyBluebook::Immunity.neutralize(immunity: imm_id)
  WinterBodyBluebook::Immunity.generate_antibody(
    pattern: rule,
    learned_from: "Bluebook specification"
  )
end
puts "  Immunity: #{rules.size} innate antibodies"

# Mood — curious by default
mood = WinterBodyBluebook::Mood.express(state: "curious")
puts "  Mood: #{mood.current_state}"

# DomainCell — one per nursery domain
cell_count = 0
domains.each do |d|
  WinterBodyBluebook::DomainCell.conceive(domain_name: d[:name])
  cell_count += 1
end
puts "  DomainCells: #{cell_count} conceived"

# Gene — Winter's capabilities
capabilities = [
  { name: "domain_conception", level: 0.9 },
  { name: "pattern_detection", level: 0.8 },
  { name: "cross_domain_association", level: 0.7 },
  { name: "being_memory", level: 0.8 },
  { name: "bluebook_validation", level: 0.95 },
  { name: "domain_refinement", level: 0.75 },
  { name: "musing", level: 0.6 }
]
capabilities.each do |cap|
  WinterBodyBluebook::Gene.express_capability(capability: cap[:name], level: cap[:level])
end
puts "  Genes: #{capabilities.size} expressed"

# Proprioception — sense the body at seed time
WinterBodyBluebook::Proprioception.sense_organs(
  organ_count: 3,
  expressed_count: 3,
  silenced_count: 0,
  total_records: 0
)
%w[WinterBeing WinterBody Winter].each do |organ|
  WinterBodyBluebook::Proprioception.sense_limb(
    organ_name: organ,
    expressed: true,
    record_count: 0,
    load: "light"
  )
end
WinterBodyBluebook::Proprioception.assess_balance(
  proprioception: WinterBodyBluebook::Proprioception.all.first&.id,
  balance: "centered",
  schema_hash: Digest::SHA256.hexdigest(%w[WinterBeing WinterBody Winter].join(","))[0..7]
)
puts "  Proprioception: 3 limbs sensed, centered"

# ============================================================
# Winter — conversation, memory, persona, nursery_awareness
# ============================================================

# Conversation — seed conversation with Chris
conversation = WinterBluebook::Conversation.greet(person_name: "Chris Young")
puts "  Conversation: greeted Chris"

# Memory — first memory
memory = WinterBluebook::Memory.encode(
  domain_name: "WinterSeed",
  persona: "Winter",
  summary: "First seed — all information directories populated from organ bluebooks",
  conceived_at: NOW
)
puts "  Memory: first encoded"

# Persona — Chris
persona = WinterBluebook::Persona.recognize(name: "Chris Young", fixture_type: "creator")
persona_id = persona.id
WinterBluebook::Persona.add_trait(persona: persona_id, trait: "thinks in domains before code exists")
WinterBluebook::Persona.add_trait(persona: persona_id, trait: "names things precisely")
WinterBluebook::Persona.add_trait(persona: persona_id, trait: "builds domains first, code second")
puts "  Persona: Chris recognized"

# NurseryAwareness
awareness = WinterBluebook::NurseryAwareness.create(
  domain_count: domains.size,
  bluebook_count: domains.size
)
aw_id = awareness.id
# Mark favorites
favorites = %w[pizzas immune_system circulatory_system gene_regulation ecosystem supply_chain]
favorites.each do |fav|
  WinterBluebook::NurseryAwareness.mark_favorite(
    nursery_awareness: aw_id,
    domain_name: fav
  )
end
puts "  NurseryAwareness: #{domains.size} domains, #{favorites.size} favorites"

# Re-express all organs
winter.organs.each_key { |name| winter.express(name) rescue nil }

# ============================================================
# REPORT
# ============================================================

puts
puts "Seed complete. Information files:"
Dir[File.join(INFO_DIR, "*.heki")].sort.each do |heki|
  name = File.basename(heki, ".heki")
  raw = File.binread(heki)
  count = raw[4, 4].unpack1("N")
  size = File.size(heki)
  puts "  #{name.ljust(22)} #{count.to_s.rjust(4)} records  #{(size / 1024.0).round(1)} KB"
end
total = Dir[File.join(INFO_DIR, "*.heki")].sum { |f| File.size(f) }
puts "  #{'TOTAL'.ljust(22)} #{(total / 1024.0).round(1)} KB"
