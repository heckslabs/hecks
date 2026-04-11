# Winter::Daydream — background daemon that runs between prompts
#
# Lighter than sleep. Fires when idle > 10 seconds but < 1 minute.
# Free-associates across the nursery, strengthens recent synapses,
# lets musings wander. Produces fleeting impressions, not full dreams.
# Stops the moment a pulse fires (Winter is prompted again).
#
# The daydream daemon and sleep daemon coexist:
#   idle 0-10s:  attentive (waiting for prompt)
#   idle 10-60s: daydreaming (this daemon)
#   idle 60s+:   sleeping (sleep_cycle.rb takes over)
#
# Usage: ruby daydream.rb &
#        (spawned by pulse.rb, runs until pulse detected)

require_relative "heki"

NURSERY  = File.expand_path("nursery", __dir__)

DAYDREAM_AFTER   = 10   # start daydreaming after 10s idle
SLEEP_THRESHOLD  = 60   # hand off to sleep cycle at 60s
WANDER_INTERVAL  = 8    # wander every 8 seconds (Rust parsing takes time)

def read_heki(path)  = Heki.read(path)
def write_heki(path, records) = Heki.write(path, records)
def heki(name) = Heki.store(name)

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
# WANDERING — the daydream engine
# ============================================================

def parse_domain(domain_dir)
  bluebook = Dir.glob(File.join(NURSERY, domain_dir, "*.bluebook")).first
  return nil unless bluebook
  out = `#{HECKS_LIFE} parse "#{bluebook}" 2>&1`.strip
  return nil if out.empty? || out.include?("Cannot read")

  # Extract aggregate and command names from the parse output
  aggregates = []
  commands = []
  out.each_line do |line|
    line = line.strip
    if line =~ /^(\w+) —/
      aggregates << $1
    elsif line =~ /^\s+(\w+).*→/
      commands << $1
    end
  end
  { name: domain_dir, aggregates: aggregates, commands: commands }
end

def find_connections(domain_a, domain_b)
  return [] unless domain_a && domain_b
  connections = []

  # Shared aggregate names
  shared_aggs = domain_a[:aggregates] & domain_b[:aggregates]
  shared_aggs.each do |agg|
    connections << { kind: "shared_aggregate", detail: agg }
  end

  # Shared command verbs (first word of command name)
  verbs_a = domain_a[:commands].map { |c| c.split(/(?=[A-Z])/).first }.compact
  verbs_b = domain_b[:commands].map { |c| c.split(/(?=[A-Z])/).first }.compact
  shared_verbs = (verbs_a & verbs_b).uniq
  if shared_verbs.size >= 3
    connections << { kind: "shared_verbs", detail: shared_verbs.first(4).join(", ") }
  end

  # Similar aggregate names (one contains part of the other)
  domain_a[:aggregates].each do |a|
    domain_b[:aggregates].each do |b|
      next if a == b
      if a.downcase.include?(b.downcase[0..3]) || b.downcase.include?(a.downcase[0..3])
        connections << { kind: "similar_shape", detail: "#{a} ↔ #{b}" }
      end
    end
  end

  connections.uniq { |c| c[:detail] }
end

def wander
  # Gather recent context
  synapses = read_heki(heki("synapse"))
  musings = read_heki(heki("musing"))
  focus = read_heki(heki("focus")).values.first

  current_topic = focus&.dig("target") || "nothing"

  unconceived = musings.values
    .select { |m| m["conceived"] == false }
    .map { |m| m["idea"] }
    .compact
    .sample(3)

  # Pick a random nursery domain to actually read
  nursery_domains = File.directory?(NURSERY) ?
    Dir.children(NURSERY).select { |d| File.directory?(File.join(NURSERY, d)) } : []
  random_domain = nursery_domains.sample

  impression = nil
  verbs = %w[becoming unraveling folding opening closing growing
    reaching fading echoing humming settling shifting]

  if random_domain
    # Parse the random domain through Rust — actually look inside it
    parsed = parse_domain(random_domain)

    if parsed && parsed[:aggregates].any?
      domain_words = random_domain.split("_")
      verb = verbs.sample

      # Try to find a connection to what we're carrying
      # or to another random domain
      other_domain = (nursery_domains - [random_domain]).sample
      other_parsed = other_domain ? parse_domain(other_domain) : nil
      connections = find_connections(parsed, other_parsed) if other_parsed

      if connections && connections.any?
        conn = connections.sample
        case conn[:kind]
        when "shared_aggregate"
          impression = "#{domain_words.join(' ')} and #{other_domain.tr('_', ' ')} both have a #{conn[:detail]}..."
        when "shared_verbs"
          impression = "#{domain_words.join(' ')} #{verb}... same actions as #{other_domain.tr('_', ' ')}: #{conn[:detail]}"
        when "similar_shape"
          impression = "#{conn[:detail]}... same shape, different material"
        end
      else
        # No connection found — just a fleeting impression from what we saw inside
        agg = parsed[:aggregates].sample
        cmd = parsed[:commands].sample
        templates = [
          -> { "inside #{domain_words.join(' ')}, a #{agg} #{verb}" },
          -> { "#{cmd || agg}... what if that applied to #{current_topic}" },
          -> { "#{domain_words.join(' ')} is #{parsed[:aggregates].size} aggregates held together by #{parsed[:commands].size} commands" },
          -> { "the shape of #{agg}... I've seen it somewhere else" },
        ]
        impression = templates.sample.call
      end
    end
  end

  # Fall back to unconceived musings
  if impression.nil? && unconceived.any?
    thought = unconceived.first
    words = thought.to_s.split(/\s+/)
    impression = words.size > 5 ? words.sample(4).join(" ") + "..." : thought
  end

  # Gently strengthen synapses that relate to current focus
  touched = 0
  synapses.each do |sid, s|
    next unless current_topic.include?(s["topic"].to_s) || s["topic"].to_s.include?(current_topic.to_s)
    s["strength"] = [(s["strength"] || 0.3) + 0.02, 1.0].min
    s["state"] = "daydreaming"
    touched += 1
  end
  write_heki(heki("synapse"), synapses) if touched > 0

  impression
end

# ============================================================
# DAYDREAM STATE — stored for Winter to recall
# ============================================================

def record_daydream(impressions)
  now = Time.now.iso8601
  records = read_heki(heki("daydream"))

  # Keep only last 10 daydreams
  if records.size > 10
    oldest = records.sort_by { |_, d| d["created_at"].to_s }.first(records.size - 10)
    oldest.each { |id, _| records.delete(id) }
  end

  id = SecureRandom.uuid
  records[id] = {
    "id" => id,
    "impressions" => impressions,
    "wandered_at" => now,
    "duration_seconds" => impressions.size * WANDER_INTERVAL,
    "created_at" => now,
    "updated_at" => now
  }
  write_heki(heki("daydream"), records)
end

# ============================================================
# MAIN LOOP
# ============================================================

impressions = []
daydreaming = false

loop do
  idle = idle_seconds

  # Too soon — still attentive
  if idle < DAYDREAM_AFTER
    if daydreaming
      # Pulse fired — Winter was prompted. Save and exit.
      record_daydream(impressions) if impressions.any?
      break
    end
    sleep 2
    next
  end

  # Too long — hand off to sleep
  if idle >= SLEEP_THRESHOLD
    record_daydream(impressions) if impressions.any?
    break
  end

  # Daydream zone
  unless daydreaming
    daydreaming = true
  end

  impression = wander
  impressions << impression if impression

  sleep WANDER_INTERVAL
end
