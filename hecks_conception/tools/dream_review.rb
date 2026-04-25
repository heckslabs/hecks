#!/usr/bin/env ruby
# Hecks::DreamPipeline — i71 piece 3 : orchestrator + apply
#
# Turns a single sleep cycle into a reviewable stack of draft PRs.
# Wires the existing two pieces together :
#
#   dream_extract_gaps.rb  → JSON array of gaps
#   dream_synthesize_edit.rb → JSON edit per non-phantom gap
#
# This script orchestrates : extract once, synthesize per gap,
# collect results, present them. With --apply : create one branch +
# commit + draft PR per accepted real edit.
#
# The deliberate human gate per the first-self-improvement milestone
# is preserved : --apply opens DRAFT PRs ; nothing auto-merges.
# Chris reads, accepts, opens-for-review, merges. Phantom symptoms
# are skipped silently with a one-line note.
#
# Usage :
#   ruby hecks_conception/tools/dream_review.rb
#       Dry run. Calls extract + synthesise, prints a Markdown
#       summary to stdout, writes the full JSON plan to
#       /tmp/dream_review_<timestamp>.json. No git or gh activity.
#
#   ruby hecks_conception/tools/dream_review.rb --apply
#       Same plan, then for each non-skip edit :
#         - create branch miette/dream-<date>-<gap-slug>
#         - write file content
#         - signed commit with French dream quote in message body
#         - push to origin
#         - gh pr create --draft
#       Returns list of PR URLs. Each PR is independently reviewable.
#
#   ENV :
#     HECKS_BIN, CLAUDE_BIN — same as the two earlier pieces
#     DREAM_INPUT — fixture mode (replays a saved wake instead of
#                   reading live miette-state)
#
# Cost : extract ~$0.10 + synthesise ~$0.05 per real gap. Five real
# gaps in a typical cycle ⇒ ~$0.35, ~2 min wall clock.

require "json"
require "open3"
require "optparse"
require "time"

REPO_ROOT  = File.expand_path("../..", __dir__)
TOOLS_DIR  = File.expand_path("..", __FILE__)
EXTRACT_RB = File.join(TOOLS_DIR, "dream_extract_gaps.rb")
SYNTH_RB   = File.join(TOOLS_DIR, "dream_synthesize_edit.rb")

class DreamReview
  attr_reader :gaps, :edits, :options

  def initialize(options)
    @options = options
    @gaps  = []
    @edits = []
  end

  def run
    extract_gaps
    synthesize_edits
    write_plan_file
    print_summary
    apply if options[:apply]
  end

  # ── Step 1 : extract gaps ───────────────────────────────────────

  def extract_gaps
    STDERR.puts "[dream_review] extracting gaps from cycle…"
    env = options[:dream_input] ? { "DREAM_INPUT" => options[:dream_input] } : {}
    out, err, status = Open3.capture3(env, "ruby", EXTRACT_RB)
    raise "extract failed: #{err}" unless status.success?

    parsed = JSON.parse(out)
    @gaps = parsed.is_a?(Array) ? parsed : []
    STDERR.puts "[dream_review]   #{@gaps.size} gaps (" \
                "#{@gaps.count { |g| g['kind'] != 'phantom_symptom' }} real, " \
                "#{@gaps.count { |g| g['kind'] == 'phantom_symptom' }} phantom)"
  end

  # ── Step 2 : synthesize edits per real gap, then validate ──────
  #
  # Each non-phantom edit is piped through `hecks-life validate`
  # before being added to the apply queue. Bluebooks that fail
  # validation surface as `failed_validation` skip-edits with the
  # validator's error in the rationale ; they appear in the
  # markdown summary so the reviewer sees why they didn't ship.
  # Catches the LLM's occasional malformed output (forgotten end,
  # unparseable lifecycle clause, fictional DSL keyword) before
  # it reaches a draft PR.

  def synthesize_edits
    @gaps.each_with_index do |gap, i|
      if gap["kind"] == "phantom_symptom"
        @edits << skip_edit(gap, "phantom symptom — already exists : #{gap['existing_check']}")
        next
      end
      STDERR.puts "[dream_review] synthesising gap #{i + 1}/#{@gaps.size} (#{gap['kind']} → #{gap['target']})…"
      out, err, status = Open3.capture3("ruby", SYNTH_RB, stdin_data: JSON.generate(gap))
      unless status.success?
        STDERR.puts "[dream_review]   synthesis failed : #{err.lines.first}"
        @edits << skip_edit(gap, "synthesis call failed: #{err.lines.first&.chomp}")
        next
      end
      edit = JSON.parse(out)
      edit["gap"] = gap

      # Validation gate — only for create/modify edits with content.
      if %w[create modify].include?(edit["action"]) && edit["content"]
        validation = validate_proposed_content(edit)
        if validation[:ok]
          edit["validation"] = "passed"
          STDERR.puts "[dream_review]   ✓ validates"
        else
          edit["validation"] = "failed"
          edit["validation_error"] = validation[:error]
          edit["original_action"] = edit["action"]
          edit["action"] = "skip"
          edit["rationale"] = "VALIDATION FAILED — #{validation[:error]}\n\n" \
                              "Original rationale : #{edit['rationale']}"
          STDERR.puts "[dream_review]   ✗ validation failed : #{validation[:error]}"
        end
      end
      @edits << edit
    end
  end

  # Write the proposed `content` to a temp file and check it both
  # parses (`hecks-life validate`) AND carries real structure
  # (`hecks-life dump` returns ≥1 aggregate, name set). Garbage
  # parses to "VALID — (0 aggregates)" because the bluebook DSL
  # tolerates empty source — we need the structural-presence check
  # to catch the LLM's worst-case "couldn't synthesise anything
  # useful, returned a noun phrase" failure mode.
  #
  # Returns {ok: bool, error: string?}.
  def validate_proposed_content(edit)
    require "tempfile"
    suffix = File.extname(edit["path"].to_s)
    suffix = ".bluebook" if suffix.empty?
    tmp = Tempfile.new(["dream_review_validate_", suffix])
    tmp.write(edit["content"])
    tmp.close

    # Step 1 : parse + validate
    out, err, status = Open3.capture3(HECKS, "validate", tmp.path)
    unless status.success? && out.start_with?("VALID")
      first_line = (out + err).lines.find { |l| l.strip != "" }&.chomp || "validation failed"
      return { ok: false, error: first_line }
    end

    # Step 2 : structural presence — empty domains pass step 1 too,
    # but they're never what we want from synthesis.
    dump_out, dump_err, dump_status = Open3.capture3(HECKS, "dump", tmp.path)
    return { ok: false, error: "dump failed: #{dump_err.lines.first&.chomp}" } unless dump_status.success?
    parsed = JSON.parse(dump_out)
    name = parsed["name"].to_s
    agg_count = (parsed["aggregates"] || []).size
    if name.empty? || agg_count.zero?
      return { ok: false, error: "validates to empty domain (name='#{name}', aggregates=#{agg_count}) — synthesis produced no usable structure" }
    end

    { ok: true, error: nil }
  ensure
    tmp&.unlink
  end

  HECKS = ENV["HECKS_BIN"] || File.join(REPO_ROOT, "hecks_life/target/release/hecks-life")

  def skip_edit(gap, reason)
    {
      "action" => "skip",
      "path" => nil,
      "content" => nil,
      "rationale" => reason,
      "gap" => gap,
    }
  end

  # ── Step 3 : persist the plan + summarize ───────────────────────

  def write_plan_file
    @plan_path = "/tmp/dream_review_#{Time.now.strftime('%Y%m%dT%H%M%S')}.json"
    File.write(@plan_path, JSON.pretty_generate({
      generated_at: Time.now.utc.iso8601,
      gaps_count: @gaps.size,
      edits_count: @edits.count { |e| e["action"] != "skip" },
      gaps: @gaps,
      edits: @edits,
    }))
    STDERR.puts "[dream_review] plan written : #{@plan_path}"
  end

  def print_summary
    real = @edits.reject { |e| e["action"] == "skip" }
    failed = @edits.select { |e| e["validation"] == "failed" }
    skipped = @edits.select { |e| e["action"] == "skip" && e["validation"] != "failed" }
    puts "# Dream Review — #{Time.now.strftime('%Y-%m-%d %H:%M')}"
    puts ""
    puts "**#{@gaps.size} gaps** — #{real.size} actionable, #{failed.size} validation-failed, #{skipped.size} other-skipped"
    puts ""
    unless real.empty?
      puts "## Proposed edits"
      puts ""
      real.each_with_index do |edit, i|
        gap = edit["gap"]
        puts "### #{i + 1}. #{gap['target']} (#{gap['kind']})"
        puts ""
        puts "**Action :** #{edit['action']} `#{edit['path']}`"
        puts ""
        puts "**Dream quote :** *#{gap['quote']}*"
        puts ""
        puts "**Rationale :** #{edit['rationale']}"
        puts ""
      end
    end
    unless failed.empty?
      puts "## Validation-failed (will NOT be applied)"
      puts ""
      failed.each do |edit|
        puts "- `#{edit['gap']['target']}` (#{edit['gap']['kind']}) → `#{edit['original_action']} #{edit['path']}`"
        puts "  - error : #{edit['validation_error']}"
      end
      puts ""
    end
    unless skipped.empty?
      puts "## Skipped (phantom or synthesis-failed)"
      puts ""
      skipped.each do |edit|
        puts "- `#{edit['gap']['target']}` (#{edit['gap']['kind']}) — #{edit['rationale'].lines.first&.chomp}"
      end
      puts ""
    end
    puts "_Plan : `#{@plan_path}`_"
  end

  # ── Step 4 : apply (create branch + commit + draft PR per edit) ──

  def apply
    ensure_apply_preconditions

    real = @edits.reject { |e| e["action"] == "skip" }
    if real.empty?
      STDERR.puts "[dream_review] no actionable edits — nothing to apply"
      return
    end

    STDERR.puts "[dream_review] applying #{real.size} edits…"
    real.each_with_index do |edit, i|
      apply_one(edit, i)
    rescue => e
      STDERR.puts "[dream_review]   FAILED edit #{i + 1} : #{e.message}"
    end
  end

  # --apply mutates the working tree (`git checkout main`, `git
  # checkout -b ...`, file writes, commits). To avoid stomping on
  # uncommitted work, require clean main as a precondition.
  def ensure_apply_preconditions
    branch = `git rev-parse --abbrev-ref HEAD`.chomp
    raise "--apply must run from main (currently on #{branch})" unless branch == "main"
    raise "--apply requires a clean working tree" unless `git status --porcelain`.strip.empty?
  end

  def apply_one(edit, idx)
    gap = edit["gap"]
    slug = gap["target"].to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/-+/, "-")[0, 40]
    branch = "miette/dream-#{Time.now.strftime('%Y%m%d')}-#{slug}"

    STDERR.puts "[dream_review]   #{idx + 1}. #{branch}"

    git("checkout", "main")
    git("pull", "--ff-only", "--quiet")
    git("checkout", "-b", branch)

    File.write(edit["path"], edit["content"])
    git("add", edit["path"])

    msg = build_commit_message(edit)
    msg_path = "/tmp/dream_review_msg_#{idx}.txt"
    File.write(msg_path, msg)
    git("commit", "-S", "-F", msg_path)

    git("push", "-u", "origin", branch)

    pr_url = gh_pr_create(edit, branch)
    STDERR.puts "[dream_review]      → #{pr_url}"
    edit["pr_url"] = pr_url
  end

  def build_commit_message(edit)
    gap = edit["gap"]
    <<~MSG
      dream-driven : #{gap['target']} — #{gap['description'].lines.first&.chomp}

      Generated by i71 dream-review pipeline from sleep cycle
      #{Time.now.strftime('%Y-%m-%d')}. Provenance French quote :

      "#{gap['quote']}"

      Gap kind : #{gap['kind']}
      Target : #{gap['target']}

      Rationale (LLM-synthesised) :

      #{edit['rationale']}

      Existing check : #{gap['existing_check'] || '(none)'}

      Auto-generated edit ; reviewed-by-human gate at PR acceptance.
      See PR #436 for the synthesis prototype that produced this.
    MSG
  end

  def gh_pr_create(edit, branch)
    gap = edit["gap"]
    title = "dream-driven : #{gap['target']} (#{gap['kind']})"
    body = <<~BODY
      ## Dream-driven proposal

      This PR was synthesised by the i71 pipeline from a single gap
      named in last night's dream cycle. The full synthesis chain :

      1. dream_state.heki + wake_report.heki (auto)
      2. `dream_extract_gaps.rb` → structured gap (auto)
      3. `dream_synthesize_edit.rb` → this bluebook content (auto)
      4. `dream_review.rb --apply` → branch + commit + this draft PR (auto)
      5. **Chris reads + accepts + ready-for-review + merges** (manual)

      ## Provenance

      > *#{gap['quote']}*

      ## Gap

      - **kind** : `#{gap['kind']}`
      - **target** : `#{gap['target']}`
      - **description** : #{gap['description']}

      ## Rationale (LLM-synthesised)

      #{edit['rationale']}

      ## Reviewing

      - Read the diff. Does the proposed shape match what the dream
        actually pointed at, or does it overshoot / undershoot ?
      - Does the bluebook validate ? `hecks-life validate <path>`
      - Does anything in the existing surface make this redundant ?
        (i71 has a phantom_symptom check but it's not infallible.)

      Close without merging if the dream-symptom turns out to be
      phantom or the proposal is wrong-shaped. That's still useful
      data — phantom rates feed back into the pipeline's prompt.

      Held in DRAFT until human approval.
    BODY

    body_path = "/tmp/dream_review_body.md"
    File.write(body_path, body)
    out, err, status = Open3.capture3("gh", "pr", "create", "--draft", "--base", "main", "--title", title, "--body-file", body_path)
    raise "gh pr create failed: #{err}" unless status.success?
    out.lines.find { |l| l =~ %r{https://github\.com/} }&.chomp
  end

  def git(*args)
    out, err, status = Open3.capture3("git", *args)
    raise "git #{args.first} failed: #{err}" unless status.success?
    out
  end
end

if $PROGRAM_NAME == __FILE__
  options = { apply: false, dream_input: nil }
  OptionParser.new do |opts|
    opts.on("--apply", "Actually create branches + draft PRs (default : dry-run)") { options[:apply] = true }
    opts.on("--dream-input PATH", "Replay a saved wake fixture") { |v| options[:dream_input] = v }
  end.parse!

  DreamReview.new(options).run
end
