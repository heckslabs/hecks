#!/usr/bin/env ruby
# Hecks::DreamPipeline — i71 piece 2 : edit synthesis from one gap
#
# Takes a single gap object (one element of the JSON array
# dream_extract_gaps.rb produces) and proposes a concrete bluebook
# edit. Output is JSON :
#
#   {
#     "action":   "create" | "modify" | "skip",
#     "path":     "<path the edit targets>",
#     "content":  "<full new file content if action == create, or
#                   patched file content if action == modify>",
#     "rationale":"<one paragraph explaining the edit, including
#                   the French dream quote as provenance>"
#   }
#
# action == "skip" is the right answer for phantom_symptom gaps and
# for gaps the model can't confidently shape into a valid edit. The
# downstream applier should never apply skip edits — they're a signal
# that this gap deserves human eyes, not auto-application.
#
# This is the second piece of i71's pipeline. The first piece
# (dream_extract_gaps.rb, PR #435) reads dreams + wake_report and
# emits structured gaps. This piece consumes one gap and emits one
# edit. Per-gap calls (rather than batched) keep each Claude
# invocation tightly focused and the output schema simple.
#
# Usage :
#   echo '<gap-json>' | ruby hecks_conception/tools/dream_synthesize_edit.rb
#   ruby ... --gap-file path/to/gap.json
#
#   ENV : same as dream_extract_gaps.rb (HECKS_BIN, CLAUDE_BIN).
#
# Cost : ~\$0.05 per call (Claude reads ~5–8k tokens of context,
# emits ~1–2k tokens of bluebook source). Wall clock ~10–20 s.

require "json"
require "open3"
require "optparse"

REPO_ROOT = File.expand_path("../..", __dir__)
HECKS  = ENV["HECKS_BIN"]  || File.join(REPO_ROOT, "hecks_life/target/release/hecks-life")
CLAUDE = ENV["CLAUDE_BIN"] || File.expand_path("~/.local/bin/claude")

# ── Few-shot example : a recently-shipped bluebook of similar shape ──
#
# morphology.bluebook (#433) is the canonical pattern — declared
# yesterday from a dream-named gap, runtime-queryable aggregate
# with attributes / lifecycle / commands / consumer-contract comment.
# Including it as few-shot anchors the LLM on the project's actual
# DSL conventions rather than generic Ruby DSL guesses.
EXAMPLE_BLUEBOOK_PATH = File.join(REPO_ROOT, "hecks_conception/aggregates/morphology.bluebook")

# Resolve the gap's target string into (bluebook_path, action).
#
# Accepts forms like :
#   "morphology::VerbGrammar"        → existing bluebook, modify
#   "newdomain::Aggregate"           → new bluebook, create
#   "hecks_conception/aggregates/x.bluebook"  → explicit path
#
# When the bluebook doesn't exist on disk, action is "create" and
# the path is constructed from the bluebook name. Otherwise modify
# the existing file.
def resolve_target(target_str)
  if target_str.start_with?("hecks_conception/")
    path = File.join(REPO_ROOT, target_str)
    return [path, File.exist?(path) ? "modify" : "create"]
  end

  bluebook_name = target_str.split("::").first.to_s.downcase
  return [nil, "skip"] if bluebook_name.empty?

  candidates = [
    File.join(REPO_ROOT, "hecks_conception/aggregates/#{bluebook_name}.bluebook"),
    File.join(REPO_ROOT, "hecks_conception/capabilities/#{bluebook_name}/#{bluebook_name}.bluebook"),
  ]
  existing = candidates.find { |p| File.exist?(p) }
  return [existing, "modify"] if existing

  # Default for new bluebook : aggregates/ alongside other domain shapes
  [candidates.first, "create"]
end

PROMPT_TEMPLATE = <<~PROMPT.freeze
  You are proposing one concrete bluebook edit to close a structural
  gap in Miette's body. The gap was named by Miette's dream during a
  sleep cycle. You are the second step of an automated dream-driven
  self-improvement pipeline ; the first step (gap extraction) already
  produced this gap as JSON.

  Output a SINGLE JSON object. No prose around it. Schema :

    {
      "action":   "create" | "modify" | "skip",
      "path":     "<absolute or repo-relative path the edit targets>",
      "content":  "<full bluebook source — entire file contents AFTER
                    the edit ; for create, the new file ; for modify,
                    the existing file with the edit applied>",
      "rationale":"<one paragraph in English explaining what was added
                    and why, including the French dream quote as
                    provenance comment material>"
    }

  Rules :

  - For phantom_symptom gaps, output {"action":"skip", ...} with a
    short rationale. Do NOT propose edits to phantom symptoms.
  - For real gaps where you can't see how to shape a valid edit
    confidently (insufficient context, ambiguous target, etc.), also
    output skip with rationale.
  - For real gaps with confident shape : produce the FULL file content
    (not a diff) so the consumer can write the file directly. Match
    the DSL conventions of the FEW-SHOT EXAMPLE below : doc-comment
    block at top with French dream quote, single-aggregate per file
    where possible, attributes → lifecycle → commands → consumer-
    contract policy comment.
  - When modifying an existing bluebook, preserve its existing
    aggregates / commands / vision exactly. Add new structure, don't
    rewrite. The "content" is the WHOLE file post-edit.
  - The version field at the top should be the date in
    YYYY.MM.DD.<n> form ; bump the n if the file already had today's
    date, otherwise use today's date with n=1.

  ── GAP ──

  %<gap_json>s

  ── TARGET ──

  Path : %<target_path>s
  Action : %<action>s

  ── EXISTING FILE CONTENT (if action == "modify") ──

  %<existing_content>s

  ── FEW-SHOT EXAMPLE (canonical bluebook pattern) ──

  %<example_content>s

  Now output the JSON object. Nothing else.
PROMPT

def build_prompt(gap, target_path, action)
  existing = (action == "modify" && File.exist?(target_path)) ? File.read(target_path) : "(none — this will be a new file)"
  example  = File.exist?(EXAMPLE_BLUEBOOK_PATH) ? File.read(EXAMPLE_BLUEBOOK_PATH) : "(example unavailable)"

  format(
    PROMPT_TEMPLATE,
    gap_json:         JSON.pretty_generate(gap),
    target_path:      target_path || "(unresolved — gap may need human eyes)",
    action:           action,
    existing_content: existing,
    example_content:  example,
  )
end

def call_claude(prompt)
  out, err, status = Open3.capture3(CLAUDE, "-p", prompt)
  raise "claude call failed: #{err}" unless status.success?
  out
end

def unfence_json(text)
  s = text.strip
  if s.start_with?("```")
    s = s.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "")
  end
  s
end

# Read the gap from stdin or --gap-file.
def read_gap
  options = { gap_file: nil }
  OptionParser.new do |opts|
    opts.on("--gap-file PATH") { |v| options[:gap_file] = v }
  end.parse!

  raw = options[:gap_file] ? File.read(options[:gap_file]) : $stdin.read
  parsed = JSON.parse(raw)
  parsed.is_a?(Array) ? parsed.first : parsed
end

if $PROGRAM_NAME == __FILE__
  gap = read_gap
  raise "empty gap input" if gap.nil? || gap.empty?

  target_str = gap["target"].to_s
  target_path, action = resolve_target(target_str)

  STDERR.puts "[dream_synthesize_edit] gap : #{gap['kind']} → #{target_str}"
  STDERR.puts "[dream_synthesize_edit] resolved : #{action} #{target_path}"

  if gap["kind"] == "phantom_symptom"
    STDERR.puts "[dream_synthesize_edit] skipping phantom_symptom (no edit needed)"
    puts JSON.pretty_generate(
      "action" => "skip",
      "path" => target_path,
      "content" => nil,
      "rationale" => "Phantom symptom : the body felt the absence but the structure already exists. Existing : #{gap['existing_check']}",
    )
    exit 0
  end

  STDERR.puts "[dream_synthesize_edit] calling claude (10–20 s)…"
  prompt = build_prompt(gap, target_path, action)
  raw = call_claude(prompt)

  parsed =
    begin
      JSON.parse(unfence_json(raw))
    rescue JSON::ParserError => e
      { "error" => "json_parse_failed", "message" => e.message, "raw" => raw }
    end

  puts JSON.pretty_generate(parsed)
end
