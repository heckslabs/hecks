# Winter::BulkGenerator — generate thousands of valid nursery domains
#
# Projection of BulkGenerator domain.
# Combines industries × activities × modifiers to create domain names,
# generates valid bluebooks from templates, batch-validates through Rust.
#
# Usage: ruby bulk_generate.rb 9000

TARGET = (ARGV[0] || 9000).to_i
NURSERY = File.expand_path("nursery", __dir__)
HECKS_LIFE = File.join(File.expand_path("..", __dir__), "hecks_life", "target", "debug", "hecks-life")
NOW = Time.now.strftime("%Y.%m.%d")

INDUSTRIES = %w[
  aerospace agriculture airline aquaculture architecture arts automotive
  aviation bakery banking beauty beverage biotech blockchain bookstore
  brewery cannabis cargo catering cement ceramics charity childcare
  cinema cleaning clothing coffee community compliance composting
  concrete consulting coral cosmetics coworking crane cryptocurrency
  cybersecurity dairy dance data defense delivery dental design
  diesel distillery dockyard drone drycleaning ecommerce education
  electric electronics elevator embassy emergency energy engineering
  entertainment equestrian espionage estate events excavation fabric
  fashion feed fence fermentation fertilizer fiber film fintech
  fireworks fitness flooring florist food footwear forensic forestry
  foundry franchise freight funeral furniture gallery gaming garden
  gemstone genetics geothermal glass golf grain granite greenhouse
  grocery gym harbor hardware healthcare hedge helicopter hemp herbal
  heritage highway hockey honey horse hospital hotel housing hunting
  hydroelectric hydrogen ice immigration incubator industrial ink
  insulation insurance interior invention irrigation island ivory
  janitorial jazz jewelry juice junkyard justice kennel kindergarten
  kiosk kitchen kite laboratory laundry lawn leather lending library
  lighting limestone linen livestock locksmith logistics lottery
  lumber luxury machinery magazine maintenance mall manufacturing
  maple marble marina marketing martial masonry mattress meat media
  medical membrane metal meteorology microchip midwifery military
  mineral mining mint mobile monastery monitoring mortgage mountain
  museum music nanotech natural navigation network newspaper nitrogen
  nonprofit nuclear nursery nutrition observatory ocean offshore oil
  opera optical organic orphanage orthodontic outdoor oxygen packaging
  painting palette paper parasail parking passport pasta patent
  paving pearl pediatric perfume pest petroleum pharmacy photography
  physics piano pipeline pizza planetarium planting plastics playground
  plumbing podcast police polish pollution pork postal pottery poultry
  power precision printing prison produce propane prosthetic protein
  psychiatric public publishing pulp pump puppet puzzle quarantine
  rabbit racing radar radiation radio railroad rainwater ranch
  reactor real recycling refrigeration rehabilitation religion
  remodeling renewable rental reptile rescue reservoir residential
  resort restaurant retail retirement revenue robotics rocket
  roofing rope rubber runway rural safari safety sailing salon
  salvage sand sanitation satellite sausage scaffold school science
  sculpture seafood seasonal security seed semiconductor senior
  sewage shelter shipbuilding shoe shuttle silk ski slaughterhouse
  sleep smartphone snack snow soap soccer solar sound space spa
  spice sports stadium stainless startup steam steel stone storage
  storm studio submarine sugar sunflower supermarket supplement surf
  surgery surplus sustainable swimming tea technology telecom temple
  tennis terminal textile theater therapy thermal ticket tile timber
  tire tobacco tobacco tourism tower toy tractor trade training
  transit transplant transportation trash travel trophy tropical
  truck tunnel turkey tutoring umbrella underwater uniform university
  urban utility vacuum valet valve vanilla vault vegetable vehicle
  vendor venture vertical veterinary video village vintage vinyl
  violin virtual vitamin volcano volunteer waffle warehouse warranty
  waste water wave wealth weather wedding wellness wheat wholesale
  wildlife wind window wine winter wireless wood wool workshop
  wrecking xenon yacht yarn yoga zebra zinc zoo
]

ACTIVITIES = %w[
  management operations processing distribution manufacturing
  services consulting inspection maintenance repair installation
  monitoring tracking logistics coordination scheduling
  compliance assessment evaluation certification training
  development research testing quality analysis design
  production assembly packaging storage delivery shipping
  procurement sourcing purchasing inventory planning
  accounting billing invoicing collection budgeting
  recruitment staffing onboarding retention compensation
  marketing advertising branding outreach engagement
  licensing permitting registration enrollment admission
  conservation preservation restoration remediation
  cultivation harvesting breeding extraction refining
  diagnostics treatment therapy rehabilitation prevention
  arbitration mediation negotiation settlement adjudication
  curation archival cataloging exhibition documentation
]

MODIFIERS = %w[
  advanced automated community cooperative digital emergency
  express forensic global green industrial integrated intensive
  international juvenile luxury marine metropolitan micro mobile
  modular municipal organic pediatric portable premium preventive
  rapid regional remote renewable residential rural seasonal
  specialized strategic sustainable tactical urban wholesale
]

VERBS = %w[
  Create Update Delete Remove Add Set Place Cancel Send Submit
  Approve Reject Accept Register Activate Suspend Retire
  Open Close Complete Start Stop Assign Transfer Schedule
  Record Log Track Report Inspect Review Verify Process
  Deploy Configure Build Generate Import Export Deliver Ship
]

AGGREGATE_TEMPLATES = [
  { suffix: "Record",    desc: "A tracked %s record" },
  { suffix: "Order",     desc: "An order for %s services" },
  { suffix: "Inventory", desc: "Available %s inventory" },
  { suffix: "Schedule",  desc: "Scheduling for %s operations" },
  { suffix: "Account",   desc: "A %s account" },
  { suffix: "Report",    desc: "A %s performance report" },
  { suffix: "Request",   desc: "A request for %s services" },
  { suffix: "Asset",     desc: "A managed %s asset" },
  { suffix: "Incident",  desc: "A %s incident or issue" },
  { suffix: "Policy",    desc: "A %s compliance policy" },
]

# Check existing
existing = Dir.children(NURSERY).to_set rescue Set.new

# Generate unique domain names
puts "Generating #{TARGET} domains..."
puts "Existing: #{existing.size}"

generated = []
combo_index = 0

# Industry × Activity combinations
INDUSTRIES.product(ACTIVITIES).shuffle.each do |industry, activity|
  break if generated.size >= TARGET
  name = "#{industry}_#{activity}"
  next if existing.include?(name)
  generated << { name: name, industry: industry, activity: activity, modifier: nil }
end

# Modifier × Industry × Activity for more
if generated.size < TARGET
  MODIFIERS.product(INDUSTRIES, ACTIVITIES).shuffle.each do |modifier, industry, activity|
    break if generated.size >= TARGET
    name = "#{modifier}_#{industry}_#{activity}"
    next if existing.include?(name)
    next if name.length > 60  # keep names reasonable
    generated << { name: name, industry: industry, activity: activity, modifier: modifier }
  end
end

puts "Will generate: #{generated.size}"

# Generate bluebooks
start = Time.now
written = 0
paths = []

generated.each_with_index do |domain, i|
  dir = File.join(NURSERY, domain[:name])
  path = File.join(dir, "#{domain[:name]}.bluebook")
  Dir.mkdir(dir) unless File.directory?(dir)

  # Pick 2-4 random aggregate templates
  agg_count = rand(2..4)
  aggs = AGGREGATE_TEMPLATES.sample(agg_count)

  camel_name = domain[:name].split("_").map(&:capitalize).join
  vision_parts = [domain[:industry], domain[:activity], domain[:modifier]].compact
  vision = "Manages #{vision_parts.join(' ')} from intake through completion"

  lines = []
  lines << "Hecks.bluebook \"#{camel_name}\", version: \"#{NOW}.1\" do"
  lines << "  vision \"#{vision}\""

  aggs.each do |tmpl|
    agg_name = "#{domain[:industry].capitalize}#{tmpl[:suffix]}"
    desc = tmpl[:desc] % domain[:industry]

    # Pick 2-3 commands
    cmd_count = rand(2..3)
    cmds = VERBS.sample(cmd_count)

    lines << ""
    lines << "  aggregate \"#{agg_name}\", \"#{desc}\" do"
    lines << "    attribute :name, String"
    lines << "    attribute :status, String"

    cmds.each do |verb|
      cmd_name = "#{verb}#{agg_name}"
      lines << ""
      lines << "    command \"#{cmd_name}\" do"
      lines << "      role \"Manager\""
      lines << "      description \"#{verb}s the #{domain[:industry]} #{tmpl[:suffix].downcase}\""
      lines << "      emits \"#{agg_name}#{verb}d\""
      lines << "    end"
    end

    if agg_count > 1 && tmpl == aggs.first
      lines << ""
      lines << "    lifecycle :status, default: \"pending\" do"
      lines << "      transition \"#{cmds.first}#{agg_name}\" => \"active\", from: \"pending\""
      lines << "      transition \"#{cmds.last}#{agg_name}\" => \"closed\", from: \"active\"" if cmds.size > 1
      lines << "    end"
    end

    lines << "  end"
  end

  lines << "end"

  File.write(path, lines.join("\n") + "\n")
  paths << path
  written += 1

  if written % 1000 == 0
    elapsed = Time.now - start
    rate = written / elapsed
    puts "  #{written}/#{generated.size} (#{'%.0f' % rate}/s)"
  end
end

elapsed = Time.now - start
puts "Wrote #{written} bluebooks in #{'%.1f' % elapsed}s (#{'%.0f' % (written / elapsed)}/s)"

# Batch validate
puts "Batch validating..."
valid = 0
invalid = 0
val_start = Time.now

IO.popen("#{HECKS_LIFE} validate --batch", "r+") do |io|
  paths.each { |p| io.puts p }
  io.close_write
  io.each_line do |line|
    if line.start_with?("VALID|")
      valid += 1
    elsif line.start_with?("INVALID|")
      invalid += 1
    end
  end
end

val_elapsed = Time.now - val_start
puts "Validated in #{'%.1f' % val_elapsed}s: #{valid} valid, #{invalid} invalid"
puts "Total: #{'%.1f' % (Time.now - start)}s"
