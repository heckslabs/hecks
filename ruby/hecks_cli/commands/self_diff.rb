# Hecks::CLI self_diff command
#
# Compares what generators would produce from a chapter's Domain IR
# against the actual code in the gem. Shows coverage gaps.
#
#   hecks self_diff hecksagon                # domain mode (default)
#   hecks self_diff hecksagon --framework    # framework skeleton mode
#
SELF_DIFF_CHAPTER_MAP ||= {
  "hecksagon"  => { gem: "hecksagon" },
  "bluebook"   => { gem: "bluebook" },
  "runtime"    => { gem: "hecksties" },
  "workshop"   => { gem: "hecks_workshop" },
  "targets"    => { gem: "hecks_targets" },
  "cli"        => { gem: "hecksties" },
  "extensions" => { gem: "hecksties" },
  "ai"         => { gem: "hecks_ai" },
  "rails"      => { gem: "hecks_on_rails" },
}.freeze

Hecks::CLI.handle(:self_diff) do |inv|
  chapter_name = inv.args.first
  unless chapter_name
    say "Usage: hecks self_diff <chapter> [--framework]", :red
    say "Available: #{SELF_DIFF_CHAPTER_MAP.keys.join(', ')}", :cyan
    next
  end

  key = chapter_name.downcase
  mapping = SELF_DIFF_CHAPTER_MAP[key]
  unless mapping
    say "Unknown chapter: #{chapter_name}", :red
    say "Available: #{SELF_DIFF_CHAPTER_MAP.keys.join(', ')}", :cyan
    next
  end

  require "hecks/chapters/#{key}"
  domain = Hecks::Chapters.definition_from_bluebook(key)

  gem_root = File.join(Dir.pwd, mapping[:gem])
  unless Dir.exist?(gem_root)
    say "Cannot find gem root: #{gem_root}", :red
    next
  end

  mode = options[:framework] ? :framework : :domain
  say "Self-diff: #{domain.name} (#{mode} mode) vs #{gem_root}/lib/", :cyan
  say ""

  diff = Hecks::Generators::Infrastructure::SelfHostDiff.new(
    domain, gem_root: gem_root, mode: mode
  )

  if mode == :framework
    gen = Hecks::Generators::Infrastructure::FrameworkGemGenerator.new(
      domain, gem_root: gem_root
    )
    located = gen.located_aggregates
    unlocated = gen.unlocated_aggregates

    if unlocated.any?
      say "UNLOCATED (#{unlocated.size} aggregates — no matching file found):", :red
      unlocated.each { |name| say "  #{name}", :red }
      say ""
    end

    if located.any?
      say "LOCATED (#{located.size} aggregates mapped to files):", :cyan
      located.each { |l| say "  #{l[:aggregate].ljust(30)} → #{l[:path]}", :cyan }
      say ""
    end
  end

  report = diff.summary

  { uncovered: :yellow, extra: :blue, partial: :magenta, match: :green }.each do |status, color|
    entries = report[:entries].select { |e| e.status == status }
    next if entries.empty?

    say "#{status.to_s.upcase} (#{entries.size}):", color
    entries.each do |e|
      detail = e.detail ? "  — #{e.detail}" : ""
      say "  #{e.path}#{detail}", color
    end
    say ""
  end

  say "Summary: #{report[:total]} files total", :white
  say "  #{report[:match]} match | #{report[:partial]} partial | " \
      "#{report[:uncovered]} uncovered | #{report[:extra]} extra", :white

  coverage_pct = report[:total].zero? ? 0 :
    ((report[:match] + report[:partial]) * 100.0 / report[:total]).round(1)
  color = coverage_pct > 50 ? :green : :yellow
  say "  Self-hosting coverage: #{coverage_pct}%", color
end
