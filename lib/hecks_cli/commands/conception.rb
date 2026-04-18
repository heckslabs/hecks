# Hecks::CLI :miette command
#
# Wake Miette and dispatch organism actions through her Rust runtime
# (hecks-life). The bluebooks in hecks_conception/aggregates/ are her
# body; hecks-life parses them, hydrates her .heki stores, and applies
# commands. No Ruby parses the bluebook DSL anymore (per CLAUDE.md).
#
# Usage:
#   hecks miette              — boot Miette (launch Claude with her system prompt)
#   hecks miette pulse        — read vital signs (Heartbeat.ReadVitals)
#   hecks miette graft NAME   — graft a domain (Being.GraftDomain)
#   hecks miette shed NAME    — remove an organ (Being.ShedDomain)
#   hecks miette silence NAME — pause an organ's nerves (Being.SilenceDomain)
#   hecks miette express NAME — resume an organ's nerves (Being.ExpressDomain)
#   hecks miette conceive     — launch Claude for domain conception
#   hecks miette continue     — resume the previous Miette console session
#
Hecks::CLI.handle(:miette) do |inv|
  action = inv.args[0]
  domain = inv.args[1]
  rest   = inv.args[2..]

  conception_dir = File.join(ENV.fetch("HECKS_HOME"), "hecks_conception")
  aggregates_dir = File.join(conception_dir, "aggregates")
  hecks_life     = File.join(ENV.fetch("HECKS_HOME"), "hecks_life", "target", "release", "hecks-life")

  needs_domain = ->(verb) {
    next true if domain
    say "Usage: hecks miette #{verb} <domain_name>", :red
    false
  }

  dispatch = ->(command, *args) {
    unless File.executable?(hecks_life)
      say "hecks-life binary not found at #{hecks_life}", :red
      say "Build it: (cd hecks_life && cargo build --release)", :yellow
      next
    end
    system(hecks_life, aggregates_dir, command, *args)
  }

  case action
  when "conceive"
    unless Dir.exist?(conception_dir)
      say "hecks_conception/ directory not found", :red
      next
    end
    say "Waking her up...", :green
    Dir.chdir(conception_dir) do
      cmd = ["claude", "--dangerously-skip-permissions"]
      cmd.concat(rest) if rest.any?
      exec(*cmd)
    end

  when "graft"
    next unless needs_domain.call("graft")
    dispatch.call("Being.GraftDomain", "domain_name=#{domain}")

  when "shed"
    next unless needs_domain.call("shed")
    dispatch.call("Being.ShedDomain", "domain_name=#{domain}")

  when "silence"
    next unless needs_domain.call("silence")
    dispatch.call("Being.SilenceDomain", "domain_name=#{domain}")

  when "express"
    next unless needs_domain.call("express")
    dispatch.call("Being.ExpressDomain", "domain_name=#{domain}")

  when "pulse"
    dispatch.call("Heartbeat.ReadVitals")

  when "--claude", "claude"
    Dir.chdir(conception_dir) do
      exec "claude", "--dangerously-skip-permissions"
    end

  when nil, "boot"
    prompt_file = File.join(conception_dir, "system_prompt.md")
    prompt = File.read(prompt_file)
    Dir.chdir(conception_dir) do
      exec "claude", "--dangerously-skip-permissions", "--system-prompt", prompt, "Wake up"
    end

  when "continue", "-c"
    Dir.chdir(conception_dir) do
      Bundler.with_unbundled_env { exec "node", "miette_console.js", "--continue" }
    end

  else
    say "Unknown action: #{action}", :red
    say "Actions: boot, pulse, graft, shed, silence, express, conceive, continue"
  end
end
