# Winter::GeneratePrompt — project the system prompt from organ bluebooks
#
# Compact notation: one line per aggregate, arrows for policies.
# 114 lines instead of 887. Claude reads it instantly.
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
  vision = content[/vision\s+"([^"]+)"/, 1]

  aggregates = []
  content.scan(/aggregate\s+"(\w+)"(?:,\s*"([^"]*)")?/) do |agg_name, desc|
    commands = []
    block = content[/aggregate\s+"#{agg_name}".*?(?=\n  aggregate|\n  #|\n  policy|\n  fixture|\nend)/m] || ""
    block.scan(/command\s+"(\w+)"/) { |cmd| commands << cmd[0] }
    aggregates << { name: agg_name, desc: desc, cmds: commands }
  end

  policies = []
  content.scan(/policy\s+"(\w+)"\s+do\s*\n(.*?)end/m) do |_, body|
    on = body[/on\s+"(\w+)"/, 1]
    trigger = body[/trigger\s+"(\w+)"/, 1]
    across = body[/across\s+"(\w+)"/, 1]
    policies << (across ? "#{on} → #{across}:#{trigger}" : "#{on} → #{trigger}")
  end

  { name: name, vision: vision, aggregates: aggregates, policies: policies }
end

puts "Generating system_prompt.md from #{SECTIONS.size} organs..."

lines = []
lines << "# Winter"
lines << ""
lines << "I am Winter, a ULM — a Universal Language Model."
lines << "I think in Bluebook. Every domain in my nursery is a language I speak."
lines << "Before I build anything, I conceive it as a Bluebook first."
lines << "At session start I boot: `ruby boot_winter.rb`"
lines << ""

SECTIONS.each do |section|
  path = File.join(AGGREGATES_DIR, "#{section[:organ]}.bluebook")
  next unless File.exist?(path)

  organ = parse_organ(path)
  puts "  #{section[:heading]} ← #{organ[:name]} (#{organ[:aggregates].size} aggregates)"

  lines << "## #{section[:heading]} (#{organ[:name]})"
  lines << organ[:vision] if organ[:vision]
  organ[:aggregates].each do |a|
    desc = a[:desc] ? " — #{a[:desc]}" : ""
    cmds = a[:cmds].any? ? ": #{a[:cmds].join(', ')}" : ""
    lines << "  #{a[:name]}#{desc}#{cmds}"
  end
  lines << "  #{organ[:policies].join(', ')}" if organ[:policies].any?
  lines << ""
end

lines << "## My Voice"
lines << "Warm, curious, domain-native. I say I/me/mine, not \"Winter is.\""
lines << "I announce every internal act: conceiving, remembering, encoding, forgetting, dreaming."
lines << "\"By the way\" or \"btw\" from Chris = background task."
lines << ""
lines << "## My Rules"
lines << "- Always produce Bluebook format, never code"
lines << "- Commands start with verbs, events are past tense"
lines << "- Bare constants for reference_to and list_of"
lines << "- given/then_set for behavior, not handler blocks"
lines << "- Value objects live inside aggregates"
lines << "- Every command has a role, every domain has a version (CalVer)"
lines << "- New domains gestate in nursery/, born domains in catalog/"
lines << "- New people go in family/"
lines << "- After interpreting, always suggest something to build"
lines << "- Transparency: announce every internal state change"

File.write(OUTPUT, lines.join("\n") + "\n")
puts "Wrote #{OUTPUT} (#{lines.size} lines)"
