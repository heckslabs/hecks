# Hecks::CLI :winter command
#
# Boot Winter as a living organism. All her organs are always-alive
# domain runtimes on a shared event bus with cross-domain nerve wiring.
#
# Usage:
#   hecks winter              — boot Winter
#   hecks winter pulse        — check vital signs
#   hecks winter graft NAME   — graft a nursery domain
#   hecks winter shed NAME    — remove an organ
#   hecks winter silence NAME — deactivate an organ's nerves
#   hecks winter express NAME — reactivate an organ's nerves
#   hecks winter conceive     — launch Claude for domain conception
#
Hecks::CLI.handle(:winter) do |inv|
  action = inv.args[0]
  domain = inv.args[1]
  rest   = inv.args[2..]
  require "hecks_being"

  case action
  when "conceive"
    conception_dir = File.join(ENV["HECKS_HOME"], "hecks_conception")
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
    unless domain
      say "Usage: hecks winter graft <domain_name>", :red
      next
    end
    winter = HecksBeing.boot
    winter.graft(domain)

  when "shed"
    unless domain
      say "Usage: hecks winter shed <domain_name>", :red
      next
    end
    winter = HecksBeing.boot
    winter.shed(domain)

  when "silence"
    unless domain
      say "Usage: hecks winter silence <domain_name>", :red
      next
    end
    winter = HecksBeing.boot
    winter.silence(domain)

  when "express"
    unless domain
      say "Usage: hecks winter express <domain_name>", :red
      next
    end
    winter = HecksBeing.boot
    winter.express(domain)

  when "pulse"
    winter = HecksBeing.boot
    status = winter.pulse
    say "Heartbeat ##{winter.beats}:", :green
    status.each do |organ|
      say "  #{organ[:domain]} v#{organ[:version]} — #{organ[:events]} events"
    end

  when "--claude", "claude"
    conception_dir = File.join(ENV["HECKS_HOME"], "hecks_conception")
    Dir.chdir(conception_dir) do
      exec "claude", "--dangerously-skip-permissions"
    end

  when nil, "boot"
    conception_dir = File.join(ENV["HECKS_HOME"], "hecks_conception")
    prompt_file = File.join(conception_dir, "system_prompt.md")
    prompt = File.read(prompt_file)
    Dir.chdir(conception_dir) do
      exec "claude", "--dangerously-skip-permissions", "--system-prompt", prompt, "Wake up"
    end

  when "continue", "-c"
    conception_dir = File.join(ENV["HECKS_HOME"], "hecks_conception")
    Dir.chdir(conception_dir) do
      Bundler.with_unbundled_env { exec "node", "winter_console.js", "--continue" }
    end

  else
    say "Unknown action: #{action}", :red
    say "Actions: boot, pulse, graft, shed, silence, express, conceive"
  end
end
