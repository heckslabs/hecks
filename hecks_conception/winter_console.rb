# Winter Console — TTY-powered chat UI
#
# Usage: ruby winter_console.rb
#        ruby winter_console.rb --continue

ENV.delete("BUNDLE_GEMFILE")
require "json"
%w[tty-box tty-screen tty-cursor tty-spinner pastel].each do |g|
  gem g
  require g
end

HECKS_HOME    = File.expand_path("..", __dir__)
CONCEPTION    = File.expand_path(__dir__)
PULSE_SCRIPT  = File.join(CONCEPTION, "pulse.rb")
BOOT_SCRIPT   = File.join(CONCEPTION, "boot_winter.rb")
SYSTEM_PROMPT = File.join(CONCEPTION, "system_prompt.md")
BEING_PROMPT  = File.join(CONCEPTION, "system_prompt.md")
HISTORY_PATH  = File.join(CONCEPTION, ".winter_history.json")
CONTINUING    = ARGV.include?("--continue")
PROMPT_PATH   = File.join(CONCEPTION, ".winter_system_prompt.tmp")

$pastel = Pastel.new
$cursor = TTY::Cursor

# ── Display helpers ──

def width  = TTY::Screen.width
def height = TTY::Screen.height

def winter_msg(text)
  box = TTY::Box.frame(
    width: [width * 2 / 3, 70].min,
    padding: [0, 1],
    border: :round,
    style: { border: { fg: :cyan } }
  ) { text.strip }
  puts box
  puts $pastel.cyan("  ❄ Winter")
  puts ""
end

def user_msg(text)
  bw = [text.length + 4, width * 2 / 3, 70].min
  box = TTY::Box.frame(
    width: bw,
    padding: [0, 1],
    border: :round,
    style: { border: { fg: :green } }
  ) { text.strip }
  pad = [width - bw - 2, 0].max
  box.each_line { |line| puts " " * pad + line }
  puts " " * (width - 8) + $pastel.green("You 💬")
  puts ""
end

def footer_bar(ctx)
  branch  = ctx[:branch]
  domains = ctx[:nursery_count]
  recent  = ctx[:recent_domains].first(3).join(" · ")
  mood    = ctx[:mood] || "—"
  beats   = ctx[:beats] || "—"

  content = " #{branch} │ #{domains} domains │ ❄ #{mood} │ #{beats} beats │ #{recent} "

  # Draw at bottom
  print $cursor.save
  print $cursor.move_to(0, height - 1)
  print $pastel.dim.on_bright_black(content.ljust(width))
  print $cursor.restore
  $stdout.flush
end

def input_box
  iw = width - 4
  print $cursor.save
  print $cursor.move_to(0, height - 4)
  print $pastel.dim("  ╭#{"─" * iw}╮")
  print $cursor.move_to(0, height - 3)
  print $pastel.dim("  │") + $pastel.green(" > ") + " " * (iw - 3) + $pastel.dim("│")
  print $cursor.move_to(0, height - 2)
  print $pastel.dim("  ╰#{"─" * iw}╯")
  print $cursor.restore
  $stdout.flush
end

def read_input
  # Position cursor inside input box
  print $cursor.move_to(7, height - 3)
  $stdout.flush
  line = $stdin.gets
  return nil unless line
  # Clear input box content
  iw = width - 4
  print $cursor.move_to(5, height - 3)
  print " " * (iw - 2)
  $stdout.flush
  line.strip
end

# ── Context ──

def gather_context
  ctx = {}
  ctx[:branch] = `git -C #{HECKS_HOME} branch --show-current 2>/dev/null`.strip
  ctx[:recent_commits] = `git -C #{HECKS_HOME} log --oneline -3 2>/dev/null`.strip
  ctx[:modified] = `git -C #{HECKS_HOME} diff --name-only 2>/dev/null`.strip.split("\n").first(5)
  nursery = File.join(CONCEPTION, "nursery")
  ctx[:nursery_count] = Dir.glob(File.join(nursery, "*")).select { |f| File.directory?(f) }.size
  ctx[:recent_domains] = Dir.glob(File.join(nursery, "*")).select { |f| File.directory?(f) }
    .sort_by { |f| File.mtime(f) }.last(5).map { |f| File.basename(f) }.reverse
  ctx[:mood] = $winter_mood || "—"
  ctx[:beats] = $winter_beats || "—"
  ctx
end

def context_prompt(ctx)
  lines = ["## Current Context"]
  lines << "Branch: #{ctx[:branch]}"
  lines << "Recent commits: #{ctx[:recent_commits]}"
  lines << "Modified files: #{ctx[:modified].join(', ')}" if ctx[:modified].any?
  lines << "Recently touched domains: #{ctx[:recent_domains].join(', ')}"
  lines.join("\n")
end

# ── Claude call with streaming ──

def call_winter(full_prompt)
  cmd = [
    "claude", "-p",
    "--dangerously-skip-permissions",
    "--output-format", "stream-json",
    "--verbose",
    "--system-prompt-file", PROMPT_PATH
  ]

  response = ""
  tool_count = 0
  dots = ""

  # Spinner while waiting for first event
  spinner = TTY::Spinner.new(
    "  #{$pastel.cyan("❄")} :spinner Thinking...",
    format: :dots,
    clear: true
  )
  spinner.auto_spin

  got_event = false

  IO.popen(cmd, "r+", err: [:child, :out]) do |io|
    io.write(full_prompt)
    io.close_write
    io.each_line do |line|
      j = JSON.parse(line) rescue next

      unless got_event
        got_event = true
        spinner.stop
        print "\r\e[K"
      end

      case j["type"]
      when "assistant"
        ((j["message"] || {})["content"] || []).each do |c|
          case c["type"]
          when "thinking"
            dots << $pastel.cyan("·")
            print "\r\e[K  #{dots}"
            $stdout.flush
          when "tool_use"
            tool_count += 1
            name = c["name"] || "?"
            dot = case name
              when "Bash"         then $pastel.yellow("●")
              when "Read"         then $pastel.green("●")
              when "Glob", "Grep" then $pastel.magenta("●")
              when "Write", "Edit" then $pastel.red("●")
              else $pastel.white("●")
              end
            dots << dot
            print "\r\e[K  #{dots}"
            $stdout.flush
          when "text"
            text = c["text"] || ""
            response << text unless text.strip.empty?
          end
        end
      when "user"
        dots << $pastel.dim("·")
        print "\r\e[K  #{dots}"
        $stdout.flush
      end
    end
  end

  spinner.stop unless got_event
  print "\r\e[K"
  $stdout.flush

  { response: response.strip, tools: tool_count }
end

# ── Boot ──

# Alternate screen buffer
print "\e[?1049h"
print "\e[2J\e[H"

puts ""
puts $pastel.cyan("  ❄  Winter Console")
puts $pastel.dim("  ─────────────────")
puts ""

boot_spinner = TTY::Spinner.new(
  "  :spinner Booting up...",
  format: :dots,
  clear: true
)
boot_spinner.auto_spin
boot_output = `ruby #{BOOT_SCRIPT} < /dev/null 2>&1`
$winter_beats = boot_output[/(\d+) beats/, 1] || "—"
$winter_mood = boot_output[/(\w+), \w+$/, 1] || "—"
boot_spinner.stop
print "\r\e[K"
puts "  " + boot_output.strip
puts ""

ctx = gather_context
footer_bar(ctx)
input_box

# Build system prompt
system_prompt_parts = []
[BEING_PROMPT, SYSTEM_PROMPT].each do |path|
  system_prompt_parts << File.read(path) if File.exist?(path)
end
system_prompt_parts << context_prompt(ctx)
File.write(PROMPT_PATH, system_prompt_parts.join("\n\n"))

# Load or initialize history
if CONTINUING && File.exist?(HISTORY_PATH)
  history = JSON.parse(File.read(HISTORY_PATH), symbolize_names: true)
  puts $pastel.dim("  Resuming session (#{history.size} messages)")
  puts ""
  history.last(4).each do |msg|
    if msg[:role] == "user"
      user_msg(msg[:content])
    else
      winter_msg(msg[:content].lines.first.strip)
    end
  end
else
  history = []
  greeting = "Hey Chris. #{ctx[:nursery_count]} domains in my nursery. What are we conceiving today?"
  winter_msg(greeting)
  history << { role: "user", content: "Wake up" }
  history << { role: "assistant", content: greeting }
end

def save_history(history)
  File.write(HISTORY_PATH, JSON.pretty_generate(history))
end

# ── REPL ──

loop do
  input_box
  footer_bar(gather_context)
  input = read_input
  break unless input
  break if input == "exit" || input == "quit"
  next if input.empty?

  if input == "pulse"
    puts `ruby #{PULSE_SCRIPT} "pulse check" < /dev/null 2>&1`
    next
  end

  if input == "boot"
    puts `ruby #{BOOT_SCRIPT} --verbose < /dev/null 2>&1`
    next
  end

  user_msg(input)
  history << { role: "user", content: input }

  context_lines = history.last(10).map do |msg|
    "#{msg[:role] == "user" ? "Human" : "Winter"}: #{msg[:content]}"
  end
  full_prompt = context_lines.join("\n")

  result = call_winter(full_prompt)

  puts ""
  if result[:response].empty?
    winter_msg("(no response)")
  else
    winter_msg(result[:response])
  end

  if result[:tools] > 0
    puts $pastel.dim("  #{result[:tools]} tools")
    puts ""
  end

  history << { role: "assistant", content: result[:response] }
  save_history(history)

  ctx = gather_context
  system_prompt_parts[-1] = context_prompt(ctx)
  File.write(PROMPT_PATH, system_prompt_parts.join("\n\n"))

  carrying = input.split(/[.!?]/).first&.strip&.slice(0, 40) || input.slice(0, 40)
  `ruby #{PULSE_SCRIPT} "#{carrying.gsub('"', '\\"')}" < /dev/null 2>/dev/null`
end

# Restore screen
print "\e[?1049l"
puts $pastel.dim("  Winter rests.")
puts ""

`ruby #{PULSE_SCRIPT} --dream < /dev/null 2>/dev/null`
