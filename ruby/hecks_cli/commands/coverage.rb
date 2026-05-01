# Hecks::CLI -- coverage command
#
# Compares the domain IR against data-domain tags in HTML/JS/Ruby files.
# Shows what's in the UL but missing from the app, and what's tagged
# in the app but not in the UL.
#
#   hecks coverage                    # scan current directory
#   hecks coverage --views path/to   # scan specific views directory
#
Hecks::CLI.handle(:coverage) do |inv|
  domain = resolve_domain_option
  next unless domain

  views_dir = if domain.respond_to?(:source_path) && domain.source_path
    File.dirname(domain.source_path)
  else
    Dir.pwd
  end
  scanner = Hecks::Capabilities::ProductExecutor::TagScanner

  # What's tagged in the app
  tagged = scanner.scan(views_dir)
  tagged_aggregates = tagged.keys.map { |t| t.split(".").first }.uniq
  tagged_members = tagged.keys.select { |t| t.include?(".") }

  # What's in the UL
  ul_aggregates = domain.aggregates.map(&:name)
  ul_members = []
  domain.aggregates.each do |agg|
    agg.commands.each { |c| ul_members << "#{agg.name}.#{c.name}" }
    agg.attributes.each { |a| ul_members << "#{agg.name}.#{a.name}" }
  end

  # Missing from app (in UL but no tag)
  missing_aggs = ul_aggregates - tagged_aggregates
  missing_members = ul_members.select do |m|
    agg = m.split(".").first
    tagged_aggregates.include?(agg) && !tagged.keys.any? { |t| t == m }
  end

  # Unknown tags (in app but not in UL)
  unknown_aggs = tagged_aggregates - ul_aggregates
  unknown_members = tagged_members.select do |t|
    agg = t.split(".").first
    ul_aggregates.include?(agg) && !ul_members.include?(t)
  end

  say "\e[1mUL Coverage Report\e[0m — #{domain.name}"
  say ""

  if missing_aggs.any?
    say "\e[33mAggregates with no data-domain tag:\e[0m"
    missing_aggs.each { |a| say "  #{a}" }
    say ""
  end

  if missing_members.any?
    say "\e[33mCommands/attributes with no tag:\e[0m"
    missing_members.each { |m| say "  #{m}" }
    say ""
  end

  if unknown_aggs.any?
    say "\e[31mTags referencing unknown aggregates:\e[0m"
    unknown_aggs.each { |a| say "  #{a}" }
    say ""
  end

  if unknown_members.any?
    say "\e[31mTags referencing unknown members:\e[0m"
    unknown_members.each { |m| say "  #{m}" }
    say ""
  end

  # Summary
  covered = tagged_aggregates.count { |a| ul_aggregates.include?(a) }
  total = ul_aggregates.size
  pct = total > 0 ? (covered * 100.0 / total).round : 0
  color = pct == 100 ? "\e[32m" : "\e[33m"

  say "#{color}#{covered}/#{total} aggregates tagged (#{pct}%)\e[0m"

  if missing_aggs.empty? && missing_members.empty? && unknown_aggs.empty? && unknown_members.empty?
    say "\e[32mFull coverage — UL and app are aligned.\e[0m"
  end
end
