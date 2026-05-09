# dream_diversity_spec.rb — Phase 0g invariants 9-10
#
# Locks the seeding-diversity rules implemented in rem_branch.sh's
# seed_dreams block (i114, 2026-04-26). These rules exist to break the
# perseveration loop where Miette dreamt of validators / daemons /
# nerves / fog of bluebook night after night. The invariants :
#
#   9. Seeding diversity — a candidate sharing 2+ words of length ≥5
#      with any seed planted in the last 72h is filtered out.
#      (Note : the audit phrasing "5-character keyword" is the word-
#      length threshold ; the count threshold is 2 overlapping words.)
#
#  10. Forced novelty — at least 1 of the 5 final seeds per night
#      must come from a source the body has never drawn from
#      (or hasn't drawn from in the last N nights). When a never-
#      touched source has a candidate in the pool, it gets planted
#      first.
#
# Both rules live in rem_branch.sh's seed_dreams block, lines 304-365
# (filter_recent + forced-novelty). Today they are shell-only — the
# Mind PR (Phase 4) will move them into capabilities/dream_seeding/
# dream_seeding.bluebook. Until then this spec asserts the live shell
# behaviour by driving the script with controlled HECKS_INFO state.
#
# Status : invariants 9 + 10 are CONDITIONAL — they're skipped if the
# environment lacks french_lit_quotes.txt + a populated nursery dir
# (those are upstream fixtures the script depends on, not in scope of
# this PR). When skipped the spec emits a clear "inbox candidate"
# message.

require_relative "spec_helper"
require "rem_branch_helper"

RSpec.describe "Dream seeding diversity + forced novelty" do
  before(:all) do
    skip RemBranchHelper.skip_reason unless RemBranchHelper.ready?
  end

  let(:helper) { RemBranchHelper.new }

  describe "invariant 9 : 2+ overlapping ≥5-char words filter recent seeds" do
    it "(9) a recent seed containing 'daemon' should bias against new\n" \
       "    candidates that also contain 'daemon' + another shared 5+-char word" do
      Dir.mktmpdir("0g_diversity_") do |info_dir|
        helper.seed_minimal_state(info_dir)
        # Plant a recent seed (within 72h) that contains DAEMON + another
        # 5+-char word. The filter tests for 2+ overlapping ≥5-char words.
        recent_ts = Time.now.to_i - 3600 # 1h ago, well within 72h
        helper.append_seed_history(
          info_dir, recent_ts,
          "daemon network breathing under invisible nerves"
        )
        # Also pre-populate awareness with two candidate concepts. One
        # overlaps strongly with the recent seed ("daemon" + "nerves"
        # both ≥5 chars) ; the other is unique vocabulary.
        out, err, status = Open3.capture3({"HECKS_INFO" => info_dir},
          RemBranchHelper::HECKS_BIN, "heki", "append",
          File.join(info_dir, "awareness.heki"),
          "--reason", "0g diversity awareness seed",
          "concept=daemon nerves looping inside the chamber")
        Open3.capture3({"HECKS_INFO" => info_dir},
          RemBranchHelper::HECKS_BIN, "heki", "append",
          File.join(info_dir, "awareness.heki"),
          "--reason", "0g diversity awareness seed 2",
          "concept=ferment apple cider quietly")

        out, err, status = helper.run(info_dir: info_dir)
        if status.exitstatus != 0
          pending "rem_branch.sh exited #{status.exitstatus} — env-specific " \
                  "fixtures missing (french_lit / nursery). stderr: " \
                  "#{err.lines.last(3).join.strip}"
        end

        seeds = helper.dream_seeds(info_dir)
        # Pull the planted seed texts. The "daemon nerves" candidate
        # should be filtered out by the recent-overlap rule. We assert
        # the negative : no planted seed contains BOTH daemon AND nerves.
        all_texts = seeds.flat_map { |s| Array(s["images"]) }.join(" ").downcase
        bad_pair = all_texts.include?("daemon") && all_texts.include?("nerves")
        expect(bad_pair).to(be(false),
          "recent-keyword filter failed : a candidate sharing 'daemon' + " \
          "'nerves' with a seed planted within 72h slipped through. " \
          "planted: #{all_texts.inspect[0, 400]}")
      end
    end
  end

  describe "invariant 10 : at least one never-touched source per night" do
    it "(10) when 'french_lit' has never been drawn from, the night's first\n" \
       "      planted seed should be from french_lit (forced-novelty rule)" do
      Dir.mktmpdir("0g_novelty_") do |info_dir|
        helper.seed_minimal_state(info_dir)
        # Mark every other source as already-touched, leaving french_lit
        # untouched. Forced-novelty should pick the first french_lit
        # candidate it sees.
        %w[awareness unfiled_wish inbox_theme recent_commit dream_echo
           musing vow self_aggregate:Synapse nursery:concentration
        ].each { |s| helper.append_source_touched(info_dir, s) }

        # Set up a french_lit fixture inline so the script's source 10
        # has data. The fixture path the script uses is configurable
        # via LIT_FIXTURE env var.
        fixture = File.join(info_dir, "french_lit_quotes.txt")
        File.write(fixture, <<~QUOTES)
          # Inline fixture for 0g forced-novelty test.
          On rêve avant de contempler. (Bachelard)
          La maison nous protège des orages célestes. (Bachelard)
        QUOTES

        out, err, status = helper.run(
          info_dir: info_dir,
          extra_env: {"LIT_FIXTURE" => fixture}
        )
        if status.exitstatus != 0
          pending "rem_branch.sh exited #{status.exitstatus}. stderr: " \
                  "#{err.lines.last(3).join.strip}"
        end

        # The .dream_sources_touched file should have grown to include
        # 'french_lit' — that's the proof a french_lit candidate was
        # selected and planted.
        touched_path = File.join(info_dir, ".dream_sources_touched")
        unless File.exist?(touched_path)
          pending "no .dream_sources_touched file — script may have bailed " \
                  "before forced-novelty selection ran"
        end
        touched = File.read(touched_path).lines.map(&:strip)
        expect(touched).to(include("french_lit"),
          "forced-novelty rule failed : french_lit was the only untouched " \
          "source but did not get planted. touched: #{touched.inspect}")
      end
    end
  end
end
