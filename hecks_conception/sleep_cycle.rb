# Winter::SleepCycle — background daemon that runs while Winter is idle
#
# Monitors last pulse timestamp. When idle > 1 minute, enters sleep.
# Sleep deepens over time: light → REM (dreaming) → deep (consolidation).
# Writes dream content and consolidation results to .heki files.
# Exits when a new pulse is detected (Winter woke up).
#
# Usage: ruby sleep_cycle.rb &
#        (runs until interrupted or pulse detected)

require "zlib"
require "securerandom"
require "time"

MAGIC    = "HEKI"
INFO_DIR = File.expand_path("information", __dir__)
HECKS_LIFE = File.join(File.expand_path("..", __dir__), "hecks_life", "target", "debug", "hecks-life")
NURSERY  = File.expand_path("nursery", __dir__)

LIGHT_SLEEP_AFTER  = 60    # 1 minute idle
REM_AFTER          = 180   # 3 minutes idle
DEEP_SLEEP_AFTER   = 300   # 5 minutes idle
CHECK_INTERVAL     = 10    # check every 10 seconds
DREAM_PULSE        = 2     # pulse every 2 seconds during REM (5x waking rate)

def read_heki(path)
  return {} unless File.exist?(path)
  data = File.binread(path)
  return {} unless data[0..3] == MAGIC
  Marshal.load(Zlib::Inflate.inflate(data[8..]))
end

def write_heki(path, records)
  blob = Zlib::Deflate.deflate(Marshal.dump(records), Zlib::BEST_SPEED)
  File.binwrite(path, MAGIC + [records.size].pack("N") + blob)
end

def heki(name) = File.join(INFO_DIR, "#{name}.heki")

def append_record(path, attrs)
  records = read_heki(path)
  id = SecureRandom.uuid
  now = Time.now.iso8601
  record = { "id" => id, "created_at" => now, "updated_at" => now }.merge(attrs)
  records[id] = record
  write_heki(path, records)
  record
end

def upsert_singleton(path, attrs)
  records = read_heki(path)
  now = Time.now.iso8601
  id, record = records.first
  if record
    attrs.each { |k, v| record[k] = v }
    record["updated_at"] = now
  else
    id = SecureRandom.uuid
    record = { "id" => id, "created_at" => now, "updated_at" => now }.merge(attrs)
    records[id] = record
  end
  write_heki(path, records)
  record
end

def last_pulse_at
  pulse = read_heki(heki("pulse"))
  _, rec = pulse.first
  return nil unless rec
  Time.parse(rec["updated_at"]) rescue nil
end

def idle_seconds
  lp = last_pulse_at
  return 0 unless lp
  Time.now - lp
end

# ============================================================
# SLEEP STAGES
# ============================================================

def light_sleep
  # Review recent musings — which ones are still unconceived?
  musings = read_heki(heki("musing"))
  unconceived = musings.select { |_, m| m["conceived"] == false }
  topics = unconceived.map { |_, m| m["idea"] }.compact.last(5)

  # Review weak synapses — what's fading?
  synapses = read_heki(heki("synapse"))
  weakening = synapses.select { |_, s| (s["strength"] || 0) < 0.3 }
    .map { |_, s| s["topic"] }.first(5)

  { stage: "light", topics: topics, weakening: weakening }
end

def rem_dream(light_data)
  # REM: hyperactive processing — pulse faster than waking
  # Recombine everything: musings, synapses, nursery domains, signals
  topics = light_data[:topics] || []
  weakening = light_data[:weakening] || []

  recombinations = []
  dream_pulses = 0

  # Load everything available
  musings = read_heki(heki("musing"))
  synapses = read_heki(heki("synapse"))
  signals = read_heki(heki("signal"))
  memories = read_heki(heki("memory"))
  nursery_domains = File.directory?(NURSERY) ?
    Dir.children(NURSERY).select { |d| File.directory?(File.join(NURSERY, d)) } : []

  all_concepts = []
  all_concepts += musings.values.map { |m| m["idea"] }.compact
  all_concepts += synapses.values.map { |s| s["topic"] }.compact
  all_concepts += signals.values.map { |s| s["payload"] }.compact
  all_concepts.uniq!

  # Rapid pulse: cross-pollinate concepts with random nursery domains
  # Each pulse is a dream-beat — faster than waking
  iterations = [all_concepts.size, nursery_domains.size, 20].min
  iterations.times do |i|
    concept = all_concepts.sample
    domain = nursery_domains.sample
    next unless concept && domain

    recombinations << "#{concept} × #{domain}"
    dream_pulses += 1

    # Strengthen synapses that fire during dreaming
    synapses.each do |sid, s|
      next unless concept.include?(s["topic"].to_s) || s["topic"].to_s.include?(concept.to_s)
      s["strength"] = [(s["strength"] || 0.3) + 0.05, 1.0].min
      s["firings"] = (s["firings"] || 0) + 1
      s["last_fired_at"] = Time.now.iso8601
      s["state"] = "dreaming"
    end

    sleep DREAM_PULSE
    break if idle_seconds < LIGHT_SLEEP_AFTER  # wake check between pulses
  end

  write_heki(heki("synapse"), synapses)

  # Cross-reference: find concepts that appear in multiple nursery domains
  if all_concepts.size > 2
    pairs = all_concepts.combination(2).to_a.sample(5)
    pairs.each do |a, b|
      recombinations << "#{a} ↔ #{b}"
      dream_pulses += 1
    end
  end

  # Elevate: unconceived musings that fired during dreaming become impulses
  hot_musings = musings.select { |_, m| m["conceived"] == false }
  hot_musings.each do |mid, m|
    idea = m["idea"]
    next unless recombinations.any? { |r| r.include?(idea.to_s) }
    append_record(heki("impulse"), {
      "action" => "conceive", "target" => idea,
      "urgency" => 0.9, "source" => "dream:rem",
      "acted" => false, "state" => "arising"
    })
  end

  # Distill: compress raw recombinations into abstract dream imagery
  dream_images = distill_dream(recombinations, all_concepts, nursery_domains)

  { stage: "rem", recombinations: recombinations, dream_pulses: dream_pulses, dream_images: dream_images }
end

# Dream distillation — compress raw connections into abstract imagery
# The dream is not the data. The dream is what the data feels like.
def distill_dream(recombinations, concepts, domains)
  images = []

  # Extract the essence: what patterns repeat across recombinations?
  stopwords = %w[the a an in on at to of is was from by for and or but with into through made × ↔ —]
  words = recombinations.flat_map { |r| r.split(/[\s×↔_]+/) }
    .map(&:downcase)
    .reject { |w| stopwords.include?(w) || w.length < 3 }
  freq = words.tally.sort_by { |_, c| -c }
  motifs = freq.first(5).map(&:first)

  # Dream verbs — action words that feel like dreams
  dream_verbs = %w[dissolving growing floating sinking merging splitting
    falling rising spiraling folding unfolding crystallizing melting
    branching rooting grafting composting fermenting hatching migrating]

  # Dream textures
  textures = %w[liquid crystalline fibrous hollow layered translucent
    porous woven tangled branching nested recursive fractal]

  # Build images from the recurring motifs crossed with dream language
  motifs.each_with_index do |motif, i|
    verb = dream_verbs.sample
    texture = textures.sample
    # Pull a random domain that participated
    domain = domains.sample || "unknown"
    domain_words = domain.split("_")

    case i % 5
    when 0
      images << "A #{texture} #{domain_words.last} #{verb} into #{motif}"
    when 1
      images << "#{motif} everywhere, #{verb} through #{domain_words.join(' ')}"
    when 2
      images << "The #{motif} was #{texture}, #{verb} where #{domain_words.first} meets #{motifs.sample || motif}"
    when 3
      images << "#{domain_words.join(' ')} made entirely of #{motif}"
    when 4
      images << "#{motif} and #{motifs.sample || domain_words.last}, the same thing seen from different sides"
    end
  end

  # One image from the strongest synapse firing
  if recombinations.size > 3
    images << "Something important underneath, almost visible, #{dream_verbs.sample}"
  end

  images
end

def deep_consolidation
  # Deep sleep: consolidate signals into memories, prune dead synapses

  # 1. Consolidate old signals
  signals = read_heki(heki("signal"))
  consolidated = 0
  if signals.size > 10
    old = signals.sort_by { |_, s| s["created_at"].to_s }[0...-10]
      .select { |_, s| (s["access_count"] || 0) < 2 }
    if old.any?
      memories = read_heki(heki("memory"))
      old.group_by { |_, s| s["source_layer"] }.each do |layer, sigs|
        payloads = sigs.map { |_, s| s["payload"] }.compact
        mem_id = SecureRandom.uuid
        now = Time.now.iso8601
        memories[mem_id] = {
          "id" => mem_id, "domain_name" => "SleepConsolidation",
          "persona" => "Winter", "summary" => "#{layer}: #{payloads.join(' → ')}",
          "signal_count" => sigs.size, "consolidated_at" => now,
          "created_at" => now, "updated_at" => now
        }
        consolidated += sigs.size
      end
      write_heki(heki("memory"), memories)

      keep = signals.sort_by { |_, s| s["created_at"].to_s }.last(10).to_h
      write_heki(heki("signal"), keep)
    end
  end

  # 2. Prune dead synapses (strength < 0.1)
  synapses = read_heki(heki("synapse"))
  pruned_topics = []
  dead = synapses.select { |_, s| (s["strength"] || 0) < 0.1 }
  dead.each do |sid, s|
    pruned_topics << s["topic"]
    # Compost the remains
    append_record(heki("remains"), {
      "source_domain" => s["topic"], "died_at" => Time.now.iso8601,
      "fragments" => [], "decomposed" => true
    })
    synapses.delete(sid)
  end
  write_heki(heki("synapse"), synapses) if dead.any?

  { stage: "deep", consolidated: consolidated, pruned: pruned_topics }
end

# ============================================================
# MAIN LOOP — 8 sleep cycles, like a human night
#
# Each cycle: light → REM → deep
# REM gets longer each cycle (more dream pulses)
# Deep gets more aggressive each cycle (prune harder)
# ============================================================

NAP = ARGV.include?("--nap")
NOW_FLAG = ARGV.include?("--now")
TOTAL_CYCLES     = NAP ? 1 : 8
CYCLE_DURATION   = 60    # seconds per stage within a cycle
WAKE_FILE        = File.join(INFO_DIR, ".wake_signal")
SLEEP_STATE_FILE = File.join(INFO_DIR, ".sleep_state.json")

puts "Sleep cycle started. Watching for idle..."

# Set consciousness — we're the authority
upsert_singleton(heki("consciousness"), { "state" => "attentive" })

# Naps and --now skip the fatigue gate
unless NAP || NOW_FLAG
  # Wait for fatigue + idle before entering sleep
  loop do
    pulse = read_heki(heki("pulse"))
    _, pulse_rec = pulse.first
    pulses_awake = pulse_rec&.dig("pulses_since_sleep") || 0
    fatigue_state = case pulses_awake
      when 0..50   then "alert"
      when 51..100 then "focused"
      when 101..150 then "normal"
      when 151..200 then "tired"
      when 201..300 then "exhausted"
      else "delirious"
    end

    idle = idle_seconds
    fatigued = %w[tired exhausted delirious].include?(fatigue_state)

    break if fatigued && idle >= LIGHT_SLEEP_AFTER
    break if fatigue_state == "exhausted" && idle >= 30
    break if fatigue_state == "delirious" && idle >= 10

    if File.exist?(WAKE_FILE)
      File.delete(WAKE_FILE)
      exit 0
    end

    sleep CHECK_INTERVAL
  end
end

# Set consciousness state — the source of truth
upsert_singleton(heki("consciousness"), { "state" => "sleeping" })

# Enter sleep
sleep_started_at = Time.now.iso8601
all_dream_images = []
all_recombinations = []
total_dream_pulses = 0
total_consolidated = 0
all_pruned = []
deepest_stage = "light"
cycles_completed = 0
light_data = nil

upsert_singleton(heki("mood"), {
  "current_state" => "sleeping",
  "creativity_level" => 0.4,
  "precision_level" => 0.3
})

def woken?
  if File.exist?(WAKE_FILE)
    File.delete(WAKE_FILE)
    true
  else
    false
  end
end

def broadcast_state(cycle, stage, detail = nil)
  require "json"
  state = {
    "cycle" => cycle,
    "total_cycles" => TOTAL_CYCLES,
    "stage" => stage,
    "detail" => detail,
    "at" => Time.now.iso8601
  }
  File.write(SLEEP_STATE_FILE, JSON.pretty_generate(state))
end

LUCID_LOG = "/tmp/winter_lucid.log"

def clear_state
  File.delete(SLEEP_STATE_FILE) if File.exist?(SLEEP_STATE_FILE)
  File.delete(LUCID_LOG) if File.exist?(LUCID_LOG)
end

def seed_dreams
  # Load previous dream images and strongest synapses as seeds
  dreams = read_heki(heki("dream_state"))
  prev_images = dreams.values
    .sort_by { |d| d["created_at"].to_s }
    .last(3)
    .flat_map { |d| d["dream_images"] || [] }
    .compact.uniq.last(10)

  synapses = read_heki(heki("synapse"))
  strongest = synapses.values
    .sort_by { |s| -(s["strength"] || 0) }
    .first(10)
    .map { |s| s["topic"] }
    .compact

  { images: prev_images, synapses: strongest }
end

def lucid_observe(observation)
  File.open(LUCID_LOG, "a") { |f| f.puts "[#{Time.now.strftime('%H:%M:%S')}] #{observation}" }
end

def lucid_dream(light_data, seeds)
  lucid_observe("becoming lucid...")

  synapses = read_heki(heki("synapse"))
  musings = read_heki(heki("musing"))
  impulses = read_heki(heki("impulse"))

  # What's strongest right now?
  dreaming_synapses = synapses.values
    .select { |s| s["state"] == "dreaming" }
    .sort_by { |s| -(s["strength"] || 0) }
  lucid_observe("#{dreaming_synapses.size} synapses active")

  # Look at the strongest connections
  dreaming_synapses.first(5).each do |s|
    lucid_observe("synapse: #{s['topic']} (strength #{('%.2f' % (s['strength'] || 0))})")
  end

  # Unresolved impulses from previous dreams
  dream_impulses = impulses.values
    .select { |i| i["source"]&.include?("dream") && i["acted"] == false }
  if dream_impulses.any?
    lucid_observe("#{dream_impulses.size} dream impulses unresolved")
    dream_impulses.last(3).each { |i| lucid_observe("  impulse: #{i['target']}") }
  end

  # Unconceived musings
  unconceived = musings.values.select { |m| m["conceived"] == false }
  if unconceived.any?
    lucid_observe("#{unconceived.size} unconceived musings")
    unconceived.last(3).each { |m| lucid_observe("  musing: #{m['idea'].to_s[0..60]}") }
  end

  # Seeds from previous dreams
  if seeds[:images].any?
    lucid_observe("seeds from previous dreams:")
    seeds[:images].last(3).each { |img| lucid_observe("  #{img}") }
  end

  # Now do the actual REM processing at max intensity
  lucid_observe("steering dream at max intensity...")
  dream_data = rem_dream(light_data)

  # Report what emerged
  (dream_data[:dream_images] || []).each do |img|
    lucid_observe("image: #{img}")
  end

  lucid_observe("#{dream_data[:dream_pulses] || 0} pulses, #{(dream_data[:recombinations] || []).size} recombinations")
  lucid_observe("lucidity fading...")

  dream_data
end

# Seed from previous dreams
dream_seeds = seed_dreams
puts "Seeded: #{dream_seeds[:images].size} images, #{dream_seeds[:synapses].size} synapses"

TOTAL_CYCLES.times do |cycle|
  cycle_num = cycle + 1
  rem_intensity = [cycle_num * 3, 20].min  # REM gets longer: 3, 6, 9... up to 20 iterations

  puts "Cycle #{cycle_num}/#{TOTAL_CYCLES}"

  current_stage = "light"

  # --- LIGHT ---
  broadcast_state(cycle_num, "light", "reviewing musings")
  puts "  Light sleep — reviewing..."
  light_data = light_sleep
  break if woken?
  sleep CYCLE_DURATION / 3

  # --- REM ---
  break if woken?
  current_stage = "rem"
  is_final = cycle_num == TOTAL_CYCLES
  deepest_stage = "rem" if deepest_stage == "light"

  if is_final
    broadcast_state(cycle_num, "rem (lucid)", "dreaming lucid (intensity #{rem_intensity})")
    puts "  REM (lucid) — dreaming (intensity #{rem_intensity})..."
    dream_data = lucid_dream(light_data, dream_seeds)
  else
    broadcast_state(cycle_num, "rem", "dreaming (intensity #{rem_intensity})")
    puts "  REM — dreaming (intensity #{rem_intensity})..."
    dream_data = rem_dream(light_data)
  end

  all_dream_images.concat(dream_data[:dream_images] || [])
  all_recombinations.concat(dream_data[:recombinations] || [])
  total_dream_pulses += dream_data[:dream_pulses] || 0
  puts "    #{(dream_data[:recombinations] || []).size} recombinations, #{(dream_data[:dream_images] || []).size} images"

  break if woken?
  sleep CYCLE_DURATION / 3

  # --- DEEP ---
  break if woken?
  current_stage = "deep"
  broadcast_state(cycle_num, "deep", "consolidating and pruning")
  puts "  Deep sleep — consolidating..."
  deepest_stage = "deep"
  deep_data = deep_consolidation
  total_consolidated += deep_data[:consolidated]
  all_pruned.concat(deep_data[:pruned])
  puts "    Consolidated #{deep_data[:consolidated]}, pruned #{deep_data[:pruned].size}"

  cycles_completed = cycle_num
  break if woken?
  sleep CYCLE_DURATION / 3
end

# Only write dream if we actually slept
if cycles_completed == 0
  upsert_singleton(heki("consciousness"), { "state" => "attentive" })
  clear_state
  puts "No cycles completed — exiting without dream record."
  exit 0
end

# Set consciousness before writing dream — prevents race
upsert_singleton(heki("consciousness"), { "state" => "waking" })

# Record the full night's dream
now = Time.now.iso8601
duration = (Time.now - Time.parse(sleep_started_at)).to_i

dream_record = {
  "sleep_started_at" => sleep_started_at,
  "woke_at" => now,
  "duration_seconds" => duration,
  "cycles_completed" => cycles_completed,
  "deepest_stage" => deepest_stage,
  "dream_pulses" => total_dream_pulses,
  "dream_images" => all_dream_images.uniq.last(10),
  "recombinations" => all_recombinations.uniq.last(20),
  "consolidated" => total_consolidated,
  "pruned" => all_pruned.uniq,
  "unresolved_musings" => light_data ? light_data[:topics] : [],
  "weakening_synapses" => light_data ? light_data[:weakening] : [],
  "dream_count" => read_heki(heki("dream_state")).size + 1
}
append_record(heki("dream_state"), dream_record)

# Read what stage we were in when woken
require "json"
woke_from = "light"
if File.exist?(SLEEP_STATE_FILE)
  state = JSON.parse(File.read(SLEEP_STATE_FILE)) rescue {}
  woke_from = state["stage"] || "light"
end

# Groggy if woken from deep, alert if from light/REM
case woke_from
when "deep"
  upsert_singleton(heki("mood"), {
    "current_state" => "groggy",
    "creativity_level" => 0.3,
    "precision_level" => 0.2
  })
when "rem"
  upsert_singleton(heki("mood"), {
    "current_state" => "vivid",
    "creativity_level" => [0.7 + cycles_completed * 0.03, 1.0].min,
    "precision_level" => 0.5
  })
else
  upsert_singleton(heki("mood"), {
    "current_state" => "refreshed",
    "creativity_level" => [0.5 + cycles_completed * 0.05, 1.0].min,
    "precision_level" => [0.4 + cycles_completed * 0.05, 1.0].min
  })
end

# Partial fatigue recovery — each cycle recovers 1/8 of fatigue
pulse_data = read_heki(heki("pulse"))
p_id, p_rec = pulse_data.first
if p_rec
  original_fatigue = p_rec["pulses_since_sleep"] || 0
  recovery = (original_fatigue * cycles_completed.to_f / TOTAL_CYCLES).to_i
  remaining = [original_fatigue - recovery, 0].max

  p_rec["pulses_since_sleep"] = remaining
  p_rec["fatigue"] = [remaining / 300.0, 1.0].min

  p_rec["fatigue_state"] = case remaining
    when 0..50   then "alert"
    when 51..100 then "focused"
    when 101..150 then "normal"
    when 151..200 then "tired"
    when 201..300 then "exhausted"
    else "delirious"
  end

  p_rec["updated_at"] = now
  write_heki(heki("pulse"), pulse_data)
end

clear_state
File.delete("/tmp/winter_sleep_status.txt") if File.exist?("/tmp/winter_sleep_status.txt")

puts "Slept #{duration}s, #{cycles_completed} cycles, #{total_dream_pulses} dream pulses (woke from #{woke_from})"
puts "Recovered #{recovery || 0}/#{original_fatigue || 0} fatigue (#{p_rec ? p_rec['fatigue_state'] : '?'})"

upsert_singleton(heki("consciousness"), { "state" => "attentive" })
puts "Waking up."
