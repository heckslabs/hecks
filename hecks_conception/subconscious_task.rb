# Winter::Subconscious — background worker for beneath-awareness processing
# Called by background agents to run predefined tasks.
# Manages its own process records in subconscious.heki.
#
# Usage: ruby subconscious_task.rb <task_name>
# Tasks: validate_nursery, refresh_census

require "json"
require_relative "heki"

NOW = Time.now.iso8601

INFO_DIR = Heki::INFO_DIR

def read_heki(path)  = Heki.read(path)
def write_heki(path, records) = Heki.write(path, records)
def heki(name) = Heki.store(name)

# --- Process tracking ---

def spawn_process(task, intent)
  records = read_heki(heki("subconscious"))
  id = SecureRandom.uuid
  records[id] = {
    "id" => id,
    "task" => task,
    "intent" => intent,
    "status" => "running",
    "spawned_at" => NOW,
    "completed_at" => nil,
    "findings" => [],
    "created_at" => NOW,
    "updated_at" => NOW
  }
  write_heki(heki("subconscious"), records)
  id
end

def report_finding(process_id, kind, subject, detail)
  records = read_heki(heki("subconscious"))
  rec = records[process_id]
  return unless rec
  rec["findings"] << { "kind" => kind, "subject" => subject, "detail" => detail }
  rec["updated_at"] = NOW
  write_heki(heki("subconscious"), records)
end

def complete_process(process_id)
  records = read_heki(heki("subconscious"))
  rec = records[process_id]
  return unless rec
  rec["status"] = "completed"
  rec["completed_at"] = Time.now.iso8601
  rec["updated_at"] = Time.now.iso8601
  write_heki(heki("subconscious"), records)
end

def fail_process(process_id, reason)
  records = read_heki(heki("subconscious"))
  rec = records[process_id]
  return unless rec
  rec["status"] = "failed"
  rec["completed_at"] = Time.now.iso8601
  rec["findings"] << { "kind" => "error", "subject" => "failure", "detail" => reason }
  rec["updated_at"] = Time.now.iso8601
  write_heki(heki("subconscious"), records)
end

# ============================================================
# TASKS
# ============================================================

NURSERY = File.expand_path("nursery", __dir__)
HECKS_ROOT = File.expand_path("..", __dir__)
HECKS_LIFE = File.join(HECKS_ROOT, "hecks_life", "target", "debug", "hecks-life")

def task_validate_nursery(pid)
  bluebooks = Dir.glob(File.join(NURSERY, "*/*.bluebook")).sort
  valid = 0
  invalid = 0

  # Batch mode — one Rust process for all files
  list_file = File.join(INFO_DIR, ".validate_list.tmp")
  File.write(list_file, bluebooks.join("\n") + "\n")
  output = `cat "#{list_file}" | "#{HECKS_LIFE}" validate --batch 2>&1`
  File.delete(list_file) rescue nil

  output.each_line do |line|
    line = line.strip
    if line.start_with?("VALID|")
      valid += 1
    elsif line.start_with?("INVALID|")
      parts = line.split("|", 3)
      rel = parts[1].to_s.sub(NURSERY + "/", "")
      errors = parts[2] || "unknown"
      invalid += 1
      report_finding(pid, "invalid", rel, errors)
    end
  end

  report_finding(pid, "summary", "validation",
    "#{valid} valid, #{invalid} invalid out of #{bluebooks.size} bluebooks")
end

def task_refresh_census(pid)
  bluebooks = Dir.glob(File.join(NURSERY, "*/*.bluebook"))

  census_path = heki("census")
  census_records = read_heki(census_path)
  census_id, census_rec = census_records.first

  if census_rec
    census_rec["total_domains"] = bluebooks.size
    census_rec["taken_at"] = Time.now.iso8601
    census_rec["updated_at"] = Time.now.iso8601
  else
    census_id = SecureRandom.uuid
    census_records[census_id] = {
      "id" => census_id,
      "total_domains" => bluebooks.size,
      "total_aggregates" => 0, "total_commands" => 0,
      "total_policies" => 0, "total_events" => 0,
      "total_lines" => 0, "sector_count" => 0,
      "sectors" => [], "cross_references" => 0, "errors" => 0,
      "taken_at" => Time.now.iso8601,
      "created_at" => Time.now.iso8601,
      "updated_at" => Time.now.iso8601
    }
  end
  write_heki(census_path, census_records)
  report_finding(pid, "summary", "census", "#{bluebooks.size} domains counted")
end

def task_repair_nursery(pid)
  bluebooks = Dir.glob(File.join(NURSERY, "*/*.bluebook")).sort
  repaired = 0
  skipped = 0

  bluebooks.each do |path|
    rel = path.sub(NURSERY + "/", "")
    output = `#{HECKS_LIFE} validate "#{path}" 2>&1`
    next if output.start_with?("VALID")

    errors = output.strip.split("\n").reject { |l| l.start_with?("INVALID") }
    content = File.read(path)
    changed = false

    errors.each do |err|
      if err.include?("Duplicate command name")
        # Extract: Duplicate command name: EnrollStudent (in Course)
        match = err.match(/Duplicate command name: (\w+) \(in (\w+)\)/)
        next unless match
        cmd_name = match[1]
        agg_name = match[2]
        new_name = "#{cmd_name}For#{agg_name}"

        # Only rename the SECOND occurrence (inside the named aggregate)
        in_agg = false
        lines = content.lines
        fixed_lines = []
        lines.each do |line|
          if line =~ /aggregate\s+"#{agg_name}"/
            in_agg = true
          elsif in_agg && line.strip == "end" && line =~ /^\s{2}end/
            in_agg = false
          end

          if in_agg
            fixed_lines << line.gsub(/\b#{cmd_name}\b/, new_name)
          else
            fixed_lines << line
          end
        end
        content = fixed_lines.join
        changed = true
        report_finding(pid, "repaired", rel, "duplicate #{cmd_name} → #{new_name} in #{agg_name}")
      end
    end

    if changed
      File.write(path, content)
      repaired += 1
    else
      skipped += 1
      report_finding(pid, "skipped", rel, errors.first)
    end
  end

  report_finding(pid, "summary", "repair",
    "#{repaired} repaired, #{skipped} skipped")
end

def task_find_orphan_scripts(pid)
  # Read the Projection domain's fixtures to get registered projections
  projection_path = File.join(File.expand_path("aggregates", __dir__), "projection.bluebook")
  registered = []

  if File.exist?(projection_path)
    content = File.read(projection_path)
    content.scan(/script_path:\s*"([^"]+)"/) { |m| registered << m[0] }
  end

  # Scan for all scripts in hecks_conception
  scripts = Dir.glob(File.join(__dir__, "*.rb")).map { |f| File.basename(f) }
  scripts += Dir.glob(File.join(__dir__, "*.js")).map { |f| File.basename(f) }

  orphans = scripts.reject { |s| registered.include?(s) }

  orphans.each do |s|
    report_finding(pid, "orphan", s, "script has no domain — needs a bluebook or registration in Projection")
  end

  report_finding(pid, "summary", "orphan_scan",
    "#{registered.size} registered, #{orphans.size} orphans out of #{scripts.size} scripts")
end

# ============================================================
# MAIN
# ============================================================

task_name = ARGV[0]
unless task_name
  puts "Usage: ruby subconscious_task.rb <task_name>"
  puts "Tasks: validate_nursery, refresh_census, repair_nursery, find_orphan_scripts"
  exit 1
end

tasks = {
  "validate_nursery" => ["Validate all nursery bluebooks", method(:task_validate_nursery)],
  "refresh_census"   => ["Refresh nursery domain count", method(:task_refresh_census)],
  "repair_nursery"   => ["Repair invalid nursery bluebooks", method(:task_repair_nursery)],
  "find_orphan_scripts" => ["Find scripts without a domain", method(:task_find_orphan_scripts)]
}

unless tasks.key?(task_name)
  puts "Unknown task: #{task_name}"
  puts "Available: #{tasks.keys.join(', ')}"
  exit 1
end

intent, runner = tasks[task_name]
pid = spawn_process(task_name, intent)
puts "Subconscious process #{pid} spawned: #{task_name}"

begin
  runner.call(pid)
  complete_process(pid)
  puts "Process completed."
rescue => e
  fail_process(pid, e.message)
  puts "Process failed: #{e.message}"
  exit 1
end
