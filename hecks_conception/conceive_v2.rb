# conceive_v2.rb
#
# Domain Conception v2 — vector-driven domain generation.
#
# Loads the compressed corpus, extracts structural vectors from every
# domain, then generates new domains by finding the nearest archetype
# and mapping its structure onto new vocabulary.
#
# A domain's vector:
#   [aggregate_count, avg_commands_per_agg, avg_attrs_per_agg,
#    vo_count, policy_count, ref_count, lifecycle_count,
#    max_lifecycle_depth, list_of_count]
#
# Usage:
#   ruby -I../lib conceive_v2.rb "ImmuneResponse" "biology"
#   ruby -I../lib conceive_v2.rb --batch biology_domains.txt
#   ruby -I../lib conceive_v2.rb --list   # show all vectors

require "zlib"
require "json"
require "hecks"

NURSERY = File.join(__dir__, "nursery")
CORPUS  = File.join(__dir__, "nursery.corpus.gz")

# --- Load corpus from binary format ---
def load_corpus
  data = Zlib::GzipReader.open(CORPUS) { |gz| gz.read }
  st_count, st_size, stream_size = data[0, 12].unpack("N3")
  st_blob = data[12, st_size]
  stream  = data[12 + st_size, stream_size]
  strings = st_blob.split("\n")
  { strings: strings, stream: stream }
end

# --- Load domains via Hecks DSL (richer than binary for vectorization) ---
def load_all_domains
  bluebooks = Dir.glob(File.join(NURSERY, "**", "*.bluebook")).sort
  domains = []
  bluebooks.each do |path|
    begin
      Kernel.load(path)
      d = Hecks.last_domain
      domains << d if d
    rescue => e
      $stderr.puts "skip: #{path}: #{e.message}"
    end
  end
  domains
end

# --- Structural vector extraction ---
def vectorize(domain)
  aggs = domain.aggregates
  agg_count = aggs.size
  cmd_counts = aggs.map { |a| a.commands.size }
  attr_counts = aggs.map { |a| a.attributes.size }
  vo_count = aggs.sum { |a| a.respond_to?(:value_objects) ? a.value_objects.size : 0 }
  ref_count = aggs.sum { |a| a.respond_to?(:references) ? a.references.size : 0 }
  policy_count = domain.policies.size + aggs.sum { |a| a.respond_to?(:policies) ? a.policies.size : 0 }
  lifecycle_count = aggs.count { |a| a.respond_to?(:lifecycle) && a.lifecycle }
  list_of_count = aggs.sum { |a| a.attributes.count { |at| at.respond_to?(:list?) && at.list? } }

  # Lifecycle depth: count transitions
  max_lc_depth = aggs.map { |a|
    next 0 unless a.respond_to?(:lifecycle) && a.lifecycle
    a.lifecycle.respond_to?(:transitions) ? a.lifecycle.transitions.size : 0
  }.max || 0

  {
    name: domain.name,
    vec: [
      agg_count,
      agg_count > 0 ? (cmd_counts.sum.to_f / agg_count).round(1) : 0,
      agg_count > 0 ? (attr_counts.sum.to_f / agg_count).round(1) : 0,
      vo_count,
      policy_count,
      ref_count,
      lifecycle_count,
      max_lc_depth,
      list_of_count
    ]
  }
end

VEC_LABELS = %w[aggs cmds/agg attrs/agg VOs policies refs lifecycles lc_depth list_ofs]

# --- Cosine similarity ---
def cosine(a, b)
  dot = a.zip(b).sum { |x, y| x * y }
  mag_a = Math.sqrt(a.sum { |x| x**2 })
  mag_b = Math.sqrt(b.sum { |x| x**2 })
  return 0.0 if mag_a == 0 || mag_b == 0
  dot / (mag_a * mag_b)
end

# --- Find k nearest domains by vector ---
def nearest(target_vec, all_vectors, k: 5)
  all_vectors
    .map { |v| { name: v[:name], vec: v[:vec], sim: cosine(target_vec, v[:vec]) } }
    .sort_by { |v| -v[:sim] }
    .first(k)
end

# --- Seed vector: estimate from description keywords ---
SHAPE_HINTS = {
  # keyword => vector bias [aggs, cmds/agg, attrs/agg, VOs, policies, refs, lifecycles, lc_depth, list_ofs]
  "lifecycle"    => [0, 0, 0, 0, 0, 0, 2, 3, 0],
  "pipeline"     => [4, 2, 3, 1, 3, 2, 2, 3, 1],
  "feedback"     => [3, 2, 2, 0, 3, 1, 1, 2, 0],
  "cascade"      => [3, 3, 2, 1, 3, 2, 1, 2, 1],
  "hierarchy"    => [3, 2, 3, 0, 1, 3, 1, 1, 1],
  "inventory"    => [3, 3, 4, 2, 1, 1, 1, 2, 2],
  "tracking"     => [4, 3, 3, 1, 2, 2, 2, 4, 1],
  "approval"     => [3, 3, 3, 0, 2, 2, 2, 4, 0],
  "self-ref"     => [2, 2, 3, 0, 0, 2, 0, 0, 1],
  "event-heavy"  => [4, 4, 3, 1, 3, 2, 2, 3, 1],
  "simple"       => [2, 2, 3, 1, 0, 0, 0, 0, 1],
  "complex"      => [5, 3, 4, 3, 3, 3, 3, 4, 2],
  "biology"      => [4, 3, 3, 2, 3, 2, 2, 3, 1],
  "ecosystem"    => [4, 2, 3, 1, 3, 2, 2, 2, 1],
  "cellular"     => [3, 3, 3, 1, 3, 1, 2, 3, 1],
  "molecular"    => [3, 3, 2, 2, 2, 1, 1, 2, 1],
}

def seed_vector(description, hints = [])
  base = [3, 2.5, 3, 1, 2, 1, 1, 2, 1]  # average domain shape
  words = (description.downcase.split(/\W+/) + hints.map(&:downcase)).uniq
  matched = words.select { |w| SHAPE_HINTS.key?(w) }
  return base if matched.empty?

  # Average the matching hint vectors
  hint_vecs = matched.map { |w| SHAPE_HINTS[w] }
  averaged = base.each_index.map { |i|
    (base[i] + hint_vecs.sum { |v| v[i] }) / (1 + hint_vecs.size).to_f
  }
  averaged
end

# --- Anticorruption Layer ---
# Builds a language map from archetype → target domain, then translates
# every term through it. No archetype vocabulary leaks into the output.

class AnticorruptionLayer
  attr_reader :noun_map, :verb_map, :attr_map, :vo_map, :event_map, :cmd_map, :role_map, :state_map

  def initialize(archetype, target_name, nouns, verbs, attrs, vos, roles)
    @target_name = target_name

    # Build noun map: archetype aggregate names → target aggregate names
    arch_aggs = archetype.aggregates.map(&:name)
    @noun_map = {}
    arch_aggs.each_with_index { |a, i| @noun_map[a] = nouns[i] if nouns[i] }

    # Build verb map: positional — verbs[i] maps to archetype's ith unique verb
    @verb_map = {}
    seen_verbs = []
    archetype.aggregates.each do |agg|
      agg.commands.each do |cmd|
        v = extract_verb(cmd.name)
        seen_verbs << v unless seen_verbs.include?(v)
      end
    end
    seen_verbs.each_with_index { |v, i| @verb_map[v] = verbs[i] if verbs[i] }

    # Build kv maps from src=tgt pairs
    @attr_map  = parse_kv(attrs)
    @vo_map    = parse_kv(vos)
    @role_map  = parse_kv(roles)

    # Auto-derive state map from lifecycle states — map archetype states to
    # snake_cased target nouns where possible
    @state_map = {}
    archetype.aggregates.each do |agg|
      next unless agg.respond_to?(:lifecycle) && agg.lifecycle
      lc = agg.lifecycle
      target_agg = @noun_map[agg.name] || agg.name
      lc.transitions.each do |_, t|
        # Map states that contain archetype-specific terms
        [t.target, t.from].compact.each do |state|
          unless @state_map.key?(state)
            # If state contains an archetype noun, translate it
            new_state = state
            @noun_map.each { |src, tgt| new_state = new_state.gsub(/#{src.downcase}/i, tgt.downcase) }
            @state_map[state] = new_state if new_state != state
          end
        end
      end
    end

    # Derived: command name map and event name map
    @cmd_map = {}
    @event_map = {}
    archetype.aggregates.each do |agg|
      agg.commands.each do |cmd|
        new_cmd = translate_command_name(cmd.name, agg.name)
        @cmd_map[cmd.name] = new_cmd
        if cmd.respond_to?(:emits) && cmd.emits
          # Event = NounVerbed (e.g., ReactantCreated, not CreateReactanted)
          @event_map[cmd.emits] = make_event_name(new_cmd)
        end
      end
    end
  end

  def translate_noun(name)     = @noun_map[name] || name
  def translate_attr(name)     = @attr_map[name.to_s] || name
  def translate_vo(name)       = @vo_map[name] || name
  def translate_role(name)     = @role_map[name] || name
  def translate_command(name)  = @cmd_map[name] || name
  def translate_event(name)    = @event_map[name] || name
  def translate_state(name)    = @state_map[name] || name

  private

  def parse_kv(pairs)
    h = {}
    pairs.each do |mapping|
      src, tgt = mapping.split("=", 2)
      h[src.strip] = tgt.strip if src && tgt
    end
    h
  end

  def extract_verb(cmd_name)
    cmd_name.gsub(/([A-Z])/, ' \1').strip.split.first
  end

  def translate_command_name(cmd_name, agg_name)
    verb = extract_verb(cmd_name)
    new_verb = @verb_map[verb] || verb
    noun_part = cmd_name.sub(/^#{verb}/, "")
    new_noun = @noun_map[noun_part] || @noun_map[agg_name] || noun_part
    "#{new_verb}#{new_noun}"
  end

  def make_event_name(cmd_name)
    # "CreateReactant" → "ReactantCreated"
    parts = cmd_name.gsub(/([A-Z])/, ' \1').strip.split
    verb = parts.shift
    noun = parts.join
    past = verb.end_with?("e") ? "#{verb}d" : "#{verb}ed"
    "#{noun}#{past}"
  end
end

# --- Learn verb lexicon from valid corpus ---
def learn_verb_lexicon(domains)
  verbs = Hash.new(0)
  domains.each do |d|
    d.aggregates.each do |a|
      a.commands.each do |c|
        verb = c.name.gsub(/([A-Z])/, ' \1').strip.split.first
        verbs[verb] += 1
      end
    end
  end
  verbs.sort_by { |_, c| -c }.to_h
end

# --- Generate a domain Bluebook through the ACL ---
def generate_bluebook(name, archetype, acl)
  lines = ["Hecks.bluebook \"#{name}\" do"]

  archetype.aggregates.each do |template_agg|
    agg_name = acl.translate_noun(template_agg.name)
    lines << "  aggregate \"#{agg_name}\" do"
    lines << "    description \"A #{agg_name.gsub(/([A-Z])/, ' \1').strip.downcase} in the #{name} domain\""

    # Translate attributes
    template_agg.attributes.each do |attr|
      attr_name = acl.translate_attr(attr.name)
      type_str = attr.type.to_s == "String" ? "" : ", #{attr.type}"
      if attr.respond_to?(:list?) && attr.list?
        vo_type = acl.translate_vo(attr.type.to_s)
        lines << "    attribute :#{attr_name}, list_of(#{vo_type})"
      else
        lines << "    attribute :#{attr_name}#{type_str}"
      end
    end

    # Translate value objects
    if template_agg.respond_to?(:value_objects)
      template_agg.value_objects.each do |vo|
        vo_name = acl.translate_vo(vo.name)
        lines << ""
        lines << "    value_object \"#{vo_name}\" do"
        vo.attributes.each do |a|
          a_name = acl.translate_attr(a.name)
          type_str = a.type.to_s == "String" ? "" : ", #{a.type}"
          lines << "      attribute :#{a_name}#{type_str}"
        end
        lines << "    end"
      end
    end

    # Translate commands (deduplicate by translated name)
    seen_cmds = {}
    template_agg.commands.each do |cmd|
      new_cmd = acl.translate_command(cmd.name)
      next if seen_cmds[new_cmd]  # skip duplicate translated commands
      seen_cmds[new_cmd] = true
      new_role = cmd.respond_to?(:role) && cmd.role ? acl.translate_role(cmd.role) : nil
      new_event = cmd.respond_to?(:emits) && cmd.emits ? acl.translate_event(cmd.emits) : nil

      lines << ""
      lines << "    command \"#{new_cmd}\" do"
      lines << "      role \"#{new_role}\"" if new_role
      if cmd.respond_to?(:description) && cmd.description
        lines << "      goal \"#{cmd.description}\""
      end
      if cmd.respond_to?(:attributes)
        cmd.attributes.each do |a|
          a_name = acl.translate_attr(a.name)
          type_str = a.type.to_s == "String" ? "" : ", #{a.type}"
          lines << "      attribute :#{a_name}#{type_str}"
        end
      end
      lines << "      emits \"#{new_event}\"" if new_event
      lines << "    end"
    end

    # Translate lifecycle
    if template_agg.respond_to?(:lifecycle) && template_agg.lifecycle
      lc = template_agg.lifecycle
      if lc.respond_to?(:transitions) && !lc.transitions.empty?
        default = lc.respond_to?(:default) ? lc.default : "initial"
        lines << ""
        lines << "    lifecycle :status, default: \"#{default}\" do"
        seen_transitions = {}
        lc.transitions.each do |cmd_name, transition|
          new_cmd = acl.translate_command(cmd_name.to_s)
          to_state = acl.translate_state(transition.respond_to?(:target) ? transition.target : transition.to_s)
          from_state = acl.translate_state(transition.respond_to?(:from) ? transition.from : "unknown")
          key = "#{new_cmd}=>#{to_state}"
          next if seen_transitions[key]  # skip duplicates
          seen_transitions[key] = true
          lines << "      transition \"#{new_cmd}\" => \"#{to_state}\", from: \"#{from_state}\""
        end
        lines << "    end"
      end
    end

    lines << "  end"
    lines << ""
  end

  # Translate policies
  archetype.policies.each do |pol|
    new_event = acl.translate_event(pol.event_name)
    new_trigger = acl.translate_command(pol.trigger_command)
    # Derive a policy name from the trigger
    policy_name = "#{new_trigger}On#{new_event.sub(/ed$|d$/, "")}"
    lines << "  policy \"#{policy_name}\" do"
    lines << "    on \"#{new_event}\""
    lines << "    trigger \"#{new_trigger}\""
    lines << "  end"
    lines << ""
  end

  lines << "end"
  lines.join("\n")
end

# --- Main ---
$stderr.print "Loading domains..."
domains = load_all_domains
vectors = domains.map { |d| vectorize(d) }
$stderr.puts " #{domains.size} domains, #{vectors.size} vectors"

if ARGV.include?("--list")
  # Show all vectors
  puts "%-30s %s" % ["Domain", VEC_LABELS.join("  ")]
  puts "-" * 100
  vectors.sort_by { |v| -v[:vec][0] }.each do |v|
    puts "%-30s %s" % [v[:name], v[:vec].map { |x| "%5s" % x }.join("  ")]
  end

  # Show clusters
  puts "\n--- Shape Clusters ---"
  clusters = vectors.group_by { |v|
    a, c = v[:vec][0], v[:vec][4]
    case
    when a <= 2 && c == 0 then "simple"
    when c >= 3            then "policy-heavy"
    when v[:vec][7] >= 3   then "lifecycle-deep"
    when v[:vec][5] >= 3   then "reference-heavy"
    when v[:vec][8] >= 2   then "list-heavy"
    else                        "balanced"
    end
  }
  clusters.each do |label, members|
    puts "\n  #{label} (#{members.size}):"
    members.each { |m| puts "    #{m[:name]}" }
  end

elsif ARGV.include?("--batch")
  # Batch mode: read domain specs from file
  # Format: Name|hints|nouns|verbs|attrs|vos|roles
  #   nouns: comma-separated, positional match to archetype aggregates
  #   verbs: comma-separated, positional match to archetype commands
  #   attrs: comma-separated src=tgt pairs (e.g., gene_id=isotope_id)
  #   vos:   comma-separated src=tgt pairs (e.g., AminoAcid=DecayProduct)
  #   roles: comma-separated src=tgt pairs (e.g., Ribosome=Reactor)
  verb_lexicon = learn_verb_lexicon(domains)
  $stderr.puts "Verb lexicon: #{verb_lexicon.size} verbs (top: #{verb_lexicon.first(5).map(&:first).join(', ')})"

  file = ARGV[ARGV.index("--batch") + 1]
  specs = File.readlines(file).map(&:strip).reject(&:empty?)
  specs.select! { |s| !s.start_with?("#") }  # skip comments

  specs.each do |spec|
    parts = spec.split("|")
    name   = parts[0]&.strip || next
    hints  = parts[1]&.split(",")&.map(&:strip) || []
    nouns  = parts[2]&.split(",")&.map(&:strip) || []
    verbs  = parts[3]&.split(",")&.map(&:strip) || []
    attrs  = parts[4]&.split(",")&.map(&:strip) || []
    vos    = parts[5]&.split(",")&.map(&:strip) || []
    roles  = parts[6]&.split(",")&.map(&:strip) || []

    seed = seed_vector(name, hints)
    top = nearest(seed, vectors, k: 3)
    archetype = domains.find { |d| d.name == top.first[:name] }

    acl = AnticorruptionLayer.new(archetype, name, nouns, verbs, attrs, vos, roles)

    puts "=== #{name} === (nearest: #{top.first[:name]} @ #{(top.first[:sim] * 100).round(1)}%)"

    bluebook = generate_bluebook(name, archetype, acl)
    out_dir = File.join(NURSERY, name.gsub(/([A-Z])/, '_\1').downcase.sub(/^_/, ""))
    FileUtils.mkdir_p(out_dir)
    out_path = File.join(out_dir, "#{File.basename(out_dir)}.bluebook")
    File.write(out_path, bluebook)

    # Validate through the gate
    begin
      Kernel.load(out_path)
      d = Hecks.last_domain
      if d
        v, e = Hecks.validate(d)
        if v
          puts "  -> #{out_path} [VALID]"
        else
          puts "  -> #{out_path} [#{e.size} errors]"
          e.each { |err| puts "     #{err}" }
        end
      end
    rescue => ex
      puts "  -> #{out_path} [LOAD ERROR: #{ex.message}]"
    end
  end

else
  # Single domain mode
  name = ARGV[0] || "UnknownDomain"
  hints = (ARGV[1] || "").split(",")
  seed = seed_vector(name, hints)

  puts "Seed vector: #{seed.map { |x| x.round(1) }}"
  puts "Shape hints: #{hints.join(', ')}" unless hints.empty?
  puts ""

  top = nearest(seed, vectors, k: 10)
  puts "Nearest domains:"
  top.each do |t|
    puts "  %5.1f%%  %-30s %s" % [t[:sim] * 100, t[:name], t[:vec].inspect]
  end
end
