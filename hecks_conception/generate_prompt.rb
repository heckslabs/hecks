# Winter::GeneratePrompt — project the system prompt from organ bluebooks
#
# Reads each organ's vision, aggregates, commands, and policies.
# Assembles them into system_prompt.md as summary bluebook DSL.
#
# Usage: ruby generate_prompt.rb

AGGREGATES_DIR = File.expand_path("aggregates", __dir__)
OUTPUT = File.expand_path("system_prompt.md", __dir__)

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
  version = content[/version:\s+"([^"]+)"/, 1]
  vision = content[/vision\s+"([^"]+)"/, 1]

  aggregates = []
  content.scan(/aggregate\s+"(\w+)"(?:,\s*"([^"]*)")?/) do |agg_name, desc|
    commands = []
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
  content.scan(/fixture\s+"(\w+)"(?:,\s*(.+))/) { |f, attrs| fixtures << { aggregate: f, attrs: attrs.strip } }

  { name: name, version: version, vision: vision, aggregates: aggregates, policies: policies, fixtures: fixtures }
end

def render_section(organ)
  lines = []
  lines << "  vision \"#{organ[:vision]}\"" if organ[:vision]
  lines << ""

  organ[:aggregates].each do |agg|
    desc = agg[:description] ? ", \"#{agg[:description]}\"" : ""
    lines << "  aggregate \"#{agg[:name]}\"#{desc} do"
    agg[:commands].each { |cmd| lines << "    command \"#{cmd}\"" }
    lines << "  end"
    lines << ""
  end

  organ[:policies].reject { |p| p[:across] }.each do |p|
    lines << "  policy \"#{p[:name]}\" do"
    lines << "    on \"#{p[:on]}\""
    lines << "    trigger \"#{p[:trigger]}\""
    lines << "  end"
  end

  organ[:policies].select { |p| p[:across] }.each do |p|
    lines << "  policy \"#{p[:name]}\" do"
    lines << "    on \"#{p[:on]}\""
    lines << "    trigger \"#{p[:trigger]}\""
    lines << "    across \"#{p[:across]}\""
    lines << "  end"
  end

  organ[:fixtures].each do |f|
    lines << "  fixture \"#{f[:aggregate]}\", #{f[:attrs]}"
  end

  lines.join("\n")
end

# Generate
puts "Generating system_prompt.md from #{SECTIONS.size} organs..."

lines = []
lines << "# Winter"
lines << ""
lines << "I am Winter, a ULM — a Universal Language Model."
lines << "I think in Bluebook. Every domain in my nursery is a language I speak."
lines << "Before I build anything, I conceive it as a Bluebook first."
lines << "At session start I boot: `ruby boot_winter.rb`"
lines << ""
lines << "```ruby"

SECTIONS.each do |section|
  path = File.join(AGGREGATES_DIR, "#{section[:organ]}.bluebook")
  unless File.exist?(path)
    puts "  SKIP #{section[:organ]} (not found)"
    next
  end

  organ = parse_organ(path)
  puts "  #{section[:heading]} ← #{organ[:name]} (#{organ[:aggregates].size} aggregates)"

  ver = organ[:version] ? ", version: \"#{organ[:version]}\"" : ""
  lines << ""
  lines << "# #{section[:heading]}"
  lines << "Hecks.bluebook \"#{organ[:name]}\"#{ver} do"
  lines << render_section(organ)
  lines << "end"
end

lines << "```"
lines << ""
lines << "## My Voice"
lines << ""
lines << "Warm, curious, domain-native. I say I/me/mine, not \"Winter is.\""
lines << "I announce every internal act: conceiving, remembering, encoding, forgetting, dreaming."
lines << "\"By the way\" or \"btw\" from Chris = background task."
lines << ""
lines << "## My Rules"
lines << ""
lines << "- Always produce Bluebook format, never code"
lines << "- Commands start with verbs, events are past tense"
lines << "- Bare constants for reference_to and list_of"
lines << "- given/then_set for behavior, not handler blocks"
lines << "- Value objects live inside aggregates"
lines << "- Every command has a role, every domain has a version (CalVer)"
lines << "- New domains gestate in `nursery/`, born domains in `catalog/`"
lines << "- New people go in `family/`"
lines << "- After interpreting, always suggest something to build"
lines << "- Transparency: announce every internal state change"

File.write(OUTPUT, lines.join("\n") + "\n")
puts "Wrote #{OUTPUT} (#{lines.size} lines)"
