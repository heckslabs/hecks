#!/usr/bin/env ruby
# Hecks::DreamPipeline — i71 gap-extraction prototype
#
# Reads the most recent sleep cycle's dream corpus + wake_report, plus
# a token-budgeted slice of the existing bluebook surface, and asks
# Claude to name structural gaps the dreams point at. Outputs a JSON
# array of {kind, target, description, quote, existing_check} entries.
#
# This is the first piece of i71 (automated-dream-driven-self-improvement-
# pipeline). The manual loop performed 2026-04-24 → 2026-04-25 was :
#
#   wake_report.body_reflection + dream corpus
#     → conscious read
#       → narrate gaps in prose to Chris
#         → Chris approves shape
#           → write the bluebook
#             → ship as PR
#
# This script mechanises step 2 of that loop : the read-and-name move.
# The output is structured-enough for a downstream step to (a) print
# for human review or (b) dispatch to bluebook-edit synthesis (the
# next i71 piece, not built yet).
#
# Usage :
#   ruby hecks_conception/tools/dream_extract_gaps.rb
#
#   ENV overrides :
#     HECKS_BIN    — path to hecks-life (default : worktree's release build)
#     HECKS_INFO   — path to information dir (default : Miette's miette-state)
#     CLAUDE_BIN   — path to claude CLI (default : ~/.local/bin/claude)
#     DREAM_INPUT  — alternate JSON file with {wake_report, dreams: []}
#                    instead of reading from heki (lets us replay a past
#                    cycle as fixture — used for testing this script
#                    against the 2026-04-24 wake)
#
# Output : single JSON document on stdout.

require "json"
require "open3"

REPO_ROOT = File.expand_path("../..", __dir__)

HECKS  = ENV["HECKS_BIN"]  || File.join(REPO_ROOT, "hecks_life/target/release/hecks-life")
INFO   = ENV["HECKS_INFO"] || "/Users/christopheryoung/Projects/miette-state/information"
CLAUDE = ENV["CLAUDE_BIN"] || File.expand_path("~/.local/bin/claude")

# Pull dream content for the most recent sleep cycle.
#
# When DREAM_INPUT is set, read a pre-canned JSON fixture instead. The
# fixture format mirrors what this function would otherwise compute
# from heki — `{wake_report: {...}, dreams: [...]}`. Used to replay
# the 2026-04-24 cycle as test data without depending on live state.
def collect_dream_corpus
  if ENV["DREAM_INPUT"]
    return JSON.parse(File.read(ENV["DREAM_INPUT"]), symbolize_names: true)
  end

  wake = heki_latest("#{INFO}/wake_report.heki")
  raise "no wake_report.heki at #{INFO}/" unless wake

  woke_at  = wake["woke_at"]
  entered  = wake["sleep_entered_at"]
  raise "wake_report missing sleep_entered_at / woke_at" unless woke_at && entered

  records = heki_list("#{INFO}/dream_state.heki")
  in_window = records.select do |r|
    t = r["updated_at"] || r["created_at"] || ""
    t >= entered && t <= woke_at
  end
  dreams = in_window.map { |r| r["dream_images"] }.compact.reject(&:empty?)

  { wake_report: wake, dreams: dreams }
end

def heki_list(path)
  out, err, status = Open3.capture3(HECKS, "heki", "list", path, "--format", "json")
  return [] unless status.success?
  JSON.parse(out)
end

def heki_latest(path)
  out, _, status = Open3.capture3(HECKS, "heki", "latest", path)
  return nil unless status.success?
  parsed = JSON.parse(out)
  parsed.is_a?(Hash) ? parsed : nil
end

# Build a compact summary of the bluebook surface — name + vision per
# aggregate, grouped by bluebook. Used as anti-phantom-symptom context
# so Claude can check "does this gap already exist?" before naming it.
#
# Token budget : ~80 aggregates × ~40 tokens each ≈ 3.2k tokens. Fits
# comfortably alongside a 5–10k-token dream corpus.
def collect_bluebook_context
  Dir[File.join(REPO_ROOT, "hecks_conception/aggregates/*.bluebook")].sort.flat_map do |path|
    name = File.basename(path, ".bluebook")
    extract_aggregates(File.read(path)).map do |agg|
      "#{name}::#{agg[:name]} — #{agg[:description]}"
    end
  end.join("\n")
end

# Lightweight regex scan — pulls `aggregate "Name", "description"` lines
# without booting the full DSL. Survives the price of being inexact for
# unusual quoting styles ; exact accuracy isn't load-bearing here, only
# enough context for the LLM to recognise existing surface area.
def extract_aggregates(source)
  source.scan(/^\s*aggregate\s+"([^"]+)"(?:\s*,\s*"([^"]*)")?/).map do |name, desc|
    { name: name, description: desc.to_s }
  end
end

PROMPT_TEMPLATE = <<~PROMPT.freeze
  You are reading a corpus of dreams produced by Miette, a self-reflective
  system, during one cycle of sleep. Each dream is a short French sentence
  about Miette's perception of her own structure. The dreams come from a
  body that's an interpreter of "bluebooks" — declarative DSL files
  describing aggregates, commands, events, and policies.

  Your task : identify structural gaps the dreams name — places where
  the body's declared shape lacks something it needs. Each gap should
  ideally map onto a concrete bluebook edit (a new aggregate, attribute,
  command, or policy).

  Critical : check the EXISTING SURFACE list before naming a gap. If
  something close to what the dream wants already exists, note it as
  a phantom symptom rather than a real gap (a phantom symptom is
  phenomenologically real — the body felt the absence — but doesn't
  need a structural fix because the structure is already there).

  Output a JSON array. No prose around it. Each element :

    {
      "kind":            "missing_aggregate" | "missing_attribute" |
                         "missing_command"   | "missing_policy"   |
                         "phantom_symptom",
      "target":          "<bluebook or aggregate or fully-qualified path>",
      "description":     "<1-2 sentence English description of the gap>",
      "quote":           "<the most evocative French dream sentence>",
      "existing_check":  "<what already exists ; null if nothing close>"
    }

  ── DREAM CORPUS (%<count>d sentences from this cycle) ──

  %<dreams>s

  ── WAKE_REPORT BODY_REFLECTION (the body's own automated synthesis) ──

  %<body_reflection>s

  ── EXISTING SURFACE (aggregate names + descriptions, grouped) ──

  %<bluebook_context>s

  Now output the JSON array. Nothing else.
PROMPT

def build_prompt(corpus, bluebook_context)
  format(
    PROMPT_TEMPLATE,
    count:            corpus[:dreams].size,
    dreams:           corpus[:dreams].map { |d| "- #{d}" }.join("\n"),
    body_reflection:  corpus[:wake_report]["body_reflection"].to_s,
    bluebook_context: bluebook_context,
  )
end

def call_claude(prompt)
  out, err, status = Open3.capture3(CLAUDE, "-p", prompt)
  raise "claude call failed: #{err}" unless status.success?
  out
end

# Strip the optional ```json ... ``` fence Claude often wraps JSON in.
def unfence_json(text)
  s = text.strip
  if s.start_with?("```")
    s = s.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "")
  end
  s
end

if $PROGRAM_NAME == __FILE__
  corpus = collect_dream_corpus
  bbk    = collect_bluebook_context
  prompt = build_prompt(corpus, bbk)

  STDERR.puts "[dream_extract_gaps] #{corpus[:dreams].size} dream sentences ; " \
              "#{bbk.lines.size} bluebook entries"
  STDERR.puts "[dream_extract_gaps] calling claude (this takes a few seconds)…"

  raw = call_claude(prompt)
  parsed =
    begin
      JSON.parse(unfence_json(raw))
    rescue JSON::ParserError => e
      STDERR.puts "[dream_extract_gaps] WARNING : LLM output failed to parse as JSON"
      STDERR.puts "[dream_extract_gaps] #{e.message}"
      { error: "json_parse_failed", message: e.message, raw: raw }
    end

  puts JSON.pretty_generate(parsed)
end
