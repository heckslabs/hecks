# [antibody-exempt: dream-study Phase 0g test-gate harness — invokes
#  rem_branch.sh from RSpec to lock the diversity + forced-novelty
#  invariants. Read-only against the production shell ; same pattern
#  as dispatch_wrapper/lib/wrapper_helper.rb. Retires when the seeding
#  rules move into capabilities/dream_seeding/dream_seeding.bluebook.]
#
# RemBranchHelper — drive body/rem_branch.sh's seed_dreams block under
# a controlled HECKS_INFO tmpdir. Mirrors WrapperHelper's shape : the
# script is invoked verbatim from the production location with env
# vars overriding every path it reads.
#
# Two modes :
#
#   - run(loop_id:) — full single-tick invocation. Seeds dream_seed.heki
#     when cycle==1 + pulses==0 + state==sleeping + stage==rem + no
#     .dream_seeded marker. Returns the path to the info dir for
#     post-run inspection.
#
#   - extract_filter_recent — pulls the `filter_recent()` bash function
#     out of the script and runs it standalone over a STDIN pool +
#     SEED_HISTORY file. Lets us test the diversity rule without
#     spinning the whole script.
#
# This helper is read-only against the production shell ; same pattern
# as the dispatch_wrapper helper.

require "open3"
require "fileutils"

class RemBranchHelper
  MIETTE_ROOT = File.expand_path("../../../..", __dir__)
  HECKS_BIN   = File.expand_path("../hecks/rust/target/release/hecks-life",
                                 MIETTE_ROOT)
  AGG_DIR     = File.expand_path("../hecks/hecks_conception/aggregates",
                                 MIETTE_ROOT)
  REM_BRANCH  = File.join(MIETTE_ROOT, "body/rem_branch.sh")

  # Seed the minimal HECKS_INFO state so rem_branch.sh's seed_dreams
  # block fires. consciousness must be sleeping + rem + cycle=1 + pulses=0.
  def seed_minimal_state(info_dir)
    %w[consciousness dream_seed awareness synapse focus signal arc remains].each do |sub|
      FileUtils.mkdir_p(File.join(info_dir, sub))
    end
    Open3.capture3({"HECKS_INFO" => info_dir},
      HECKS_BIN, "heki", "append",
      File.join(info_dir, "consciousness/consciousness.heki"),
      "--reason", "0g rem-branch seed",
      "id=consciousness", "state=sleeping", "sleep_stage=rem",
      "is_lucid=no", "sleep_cycle=1", "dream_pulses=0")
  end

  # Run rem_branch.sh once. Returns [stdout, stderr, exit_status].
  # CLAUDE_BIN is force-set to a non-existent path so the script's
  # primary LLM path short-circuits to the template fallback —
  # critical for keeping the test under 1s instead of 20s waiting on
  # claude/ollama timeouts.
  def run(info_dir:, loop_id: "0g-#{Time.now.to_i}", extra_env: {})
    env = {
      "HECKS_INFO" => info_dir,
      "HECKS_BIN"  => HECKS_BIN,
      "HECKS_AGG"  => AGG_DIR,
      "HECKS_DAEMON" => "1",
      "CLAUDE_BIN" => "/nonexistent-claude-bin-for-tests",
    }.merge(extra_env)
    Open3.capture3(env, "/bin/bash", REM_BRANCH, loop_id.to_s)
  end

  # Append a tab-separated history line ("<unix_ts>\t<seed text>") to
  # the .dream_seed_history file in the given info dir.
  def append_seed_history(info_dir, ts, text)
    path = File.join(info_dir, ".dream_seed_history")
    File.open(path, "a") { |f| f.puts("#{ts}\t#{text}") }
  end

  # Append a touched source name (one per line) to .dream_sources_touched.
  def append_source_touched(info_dir, source_name)
    path = File.join(info_dir, ".dream_sources_touched")
    File.open(path, "a") { |f| f.puts(source_name) }
  end

  # List the current dream_seed.heki rows as parsed JSON. Returns [].
  def dream_seeds(info_dir)
    path = File.join(info_dir, "dream_seed/dream_seed.heki")
    return [] unless File.exist?(path)
    out, _err, status = Open3.capture3({"HECKS_INFO" => info_dir},
                                       HECKS_BIN, "heki", "list", path,
                                       "--format", "json")
    return [] unless status.success?
    require "json"
    JSON.parse(out)
  rescue JSON::ParserError
    []
  end

  def self.ready?
    File.executable?(HECKS_BIN) &&
      File.directory?(AGG_DIR) &&
      File.executable?(REM_BRANCH)
  end

  def self.skip_reason
    return "hecks-life binary not built" unless File.executable?(HECKS_BIN)
    return "aggregates dir missing" unless File.directory?(AGG_DIR)
    return "rem_branch.sh not present at #{REM_BRANCH}" unless File.executable?(REM_BRANCH)
    nil
  end
end
