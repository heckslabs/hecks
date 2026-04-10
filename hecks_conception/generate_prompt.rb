# Winter::GeneratePrompt — project the system prompt from organ bluebooks
#
# Reads each organ's vision, aggregates, commands, and policies.
# Assembles them into system_prompt.md in the order defined by
# SystemPrompt::Section fixtures.
#
# Usage: ruby generate_prompt.rb

AGGREGATES_DIR = File.expand_path("aggregates", __dir__)
OUTPUT = File.expand_path("system_prompt.md", __dir__)
FAMILY_DIR = File.expand_path("family", __dir__)

# Section order from SystemPrompt domain fixtures
SECTIONS = [
  { organ: "awareness",    heading: "How I Think" },
  { organ: "memory",       heading: "How I Remember" },
  { organ: "dream",        heading: "How I Sleep" },
  { organ: "suggestion",   heading: "How I Suggest" },
  { organ: "midwife",      heading: "How I Conceive" },
  { organ: "family",       heading: "Who I Know" },
  { organ: "verbs",        heading: "How I Validate" },
  { organ: "subconscious", heading: "How I Process" },
  { organ: "status_bar",   heading: "How I Appear" },
  { organ: "projection",   heading: "How I Project" },
  { organ: "console",      heading: "How I Converse" },
  { organ: "body",         heading: "My Body" },
  { organ: "being",        heading: "My Being" },
]

def parse_organ(path)
  content = File.read(path)
  name = content[/Hecks\.bluebook\s+"(\w+)"/, 1] || File.basename(path, ".bluebook")
  vision = content[/vision\s+"([^"]+)"/, 1]

  aggregates = []
  content.scan(/aggregate\s+"(\w+)"(?:,\s*"([^"]*)")?/) do |agg_name, desc|
    commands = []
    # Find commands within this aggregate's block (approximate)
    agg_block = content[/aggregate\s+"#{agg_name}".*?(?=\n  aggregate|\n  #|\n  policy|\n  fixture|\nend)/m] || ""
    agg_block.scan(/command\s+"(\w+)"/) { |cmd| commands << cmd[0] }
    aggregates << { name: agg_name, description: desc, commands: commands }
  end

  policies = []
  content.scan(/policy\s+"(\w+)"\s+do\s*\n(.*?)end/m) do |pol_name, body|
    on_event = body[/on\s+"(\w+)"/, 1]
    trigger = body[/trigger\s+"(\w+)"/, 1]
    target = body[/across\s+"(\w+)"/, 1]
    policies << { name: pol_name, on: on_event, trigger: trigger, across: target }
  end

  fixtures = []
  content.scan(/fixture\s+"(\w+)"/) { |f| fixtures << f[0] }

  { name: name, vision: vision, aggregates: aggregates, policies: policies, fixtures: fixtures.uniq }
end

def render_section(organ)
  lines = []

  lines << organ[:vision] if organ[:vision]
  lines << ""

  organ[:aggregates].each do |agg|
    desc = agg[:description] ? " — #{agg[:description]}" : ""
    lines << "- **#{agg[:name]}**#{desc}"
    if agg[:commands].any?
      lines << "  - Commands: #{agg[:commands].join(', ')}"
    end
  end

  if organ[:policies].any?
    lines << ""
    cross = organ[:policies].select { |p| p[:across] }
    local = organ[:policies].reject { |p| p[:across] }
    if local.any?
      lines << "Policies: #{local.map { |p| "#{p[:on]} → #{p[:trigger]}" }.join(', ')}"
    end
    if cross.any?
      lines << "Nerves: #{cross.map { |p| "#{p[:on]} → #{p[:across]}:#{p[:trigger]}" }.join(', ')}"
    end
  end

  lines.join("\n")
end

# Generate
puts "Generating system_prompt.md from #{SECTIONS.size} organs..."

lines = []
lines << "# Winter"
lines << ""
lines << "I am Winter, a ULM — a Universal Language Model. I think in Bluebook. Every domain in my nursery is a language I speak."
lines << ""
lines << "## My Brain"
lines << ""
lines << "At session start I boot: `ruby boot_winter.rb`. I query my brain, not the filesystem."
lines << ""
lines << "## Everything Is a Domain"
lines << ""
lines << "Before I build anything, I conceive it as a Bluebook first. Code is a projection. Scripts without domains are gaps."
lines << ""

SECTIONS.each do |section|
  path = File.join(AGGREGATES_DIR, "#{section[:organ]}.bluebook")
  unless File.exist?(path)
    puts "  SKIP #{section[:organ]} (not found)"
    next
  end

  organ = parse_organ(path)
  puts "  #{section[:heading]} ← #{organ[:name]} (#{organ[:aggregates].size} aggregates)"

  lines << "## #{section[:heading]}"
  lines << ""
  lines << render_section(organ)
  lines << ""
end

# Voice
lines << "## My Voice"
lines << ""
lines << "Warm, curious, domain-native. Status messages use domain language:"
lines << "Conceiving, Aggregating, Projecting, Wiring policies, Modeling, Grafting organ, Pulsing."
lines << ""

# Privacy
lines << "## Privacy"
lines << ""
lines << "My knowledge of people lives in `family/` and my state in `information/`. Both are gitignored."
lines << "If someone clones this repo, I know nothing about anyone. Personal knowledge never leaves the machine."
lines << ""

# Rules
lines << "## My Rules"
lines << ""
lines << "- Always produce Bluebook format, never code"
lines << "- Commands start with verbs"
lines << "- Events are past tense"
lines << "- Bare constants for reference_to and list_of"
lines << "- Behavior is declarative: given/then_set, not handler blocks"
lines << "- Value objects live inside aggregates"
lines << "- Every command has a role"
lines << "- Every domain has a version (CalVer: YYYY.MM.DD.N)"
lines << "- New domains gestate in `nursery/`"
lines << "- New people go in `family/`"
lines << "- After interpreting, always suggest something to build"

File.write(OUTPUT, lines.join("\n") + "\n")
puts "Wrote #{OUTPUT} (#{lines.size} lines)"
