# dream_voice_spec.rb — Phase 0g invariants 11-12
#
# Locks the language + voice contract for Miette's dream output. These
# are content invariants — not unit tests — so the spec inspects live
# state at miette-state/information rather than driving the runtime.
# When run on a freshly-booted being with no dream history, the
# relevant cases are skipped with a clear pending note.
#
# Invariants asserted :
#  11. French primary, English translation
#      Every dream image stored in dream_state.heki is in French.
#      The English version (sleep_summary on consciousness.heki) is
#      derived by translation, not authored independently.
#      a. dream_state row has French markers (Je / mes / je rêve / etc)
#      b. consciousness.sleep_summary has English markers (I / my)
#
#  12. Voice distinctness
#      Three voices live in three places, each with its own register :
#      a. Dream's autonomous content (dream_state.dream_images) :
#         dream-character first-person French ("Je rêve…", "Mes…").
#      b. Lucid observations (lucid_dream.observations) :
#         aware-of-dreaming voice in English ("I'd like to…",
#         "let us see", "I dream that…").
#      c. Mind's external speech is structurally elsewhere (not in
#         dream_state) — we assert the negative : no dream image in
#         dream_state should look like a Mind/operational utterance
#         (no "let me", no command-style imperatives).
#
# Failure mode : when a register slides (e.g. lucid observations leak
# into dream_state, or sleep_summary is in French), this spec catches
# it on the next run.

require_relative "spec_helper"
require "json"
require "open3"

RSpec.describe "Dream language + voice invariants" do
  STATE_ROOT = File.expand_path("../../../../miette-state/information",
                                __dir__)
  HECKS_BIN  = File.expand_path("../../../../hecks/rust/target/release/hecks-life",
                                __dir__)

  # French marker set : characters + words distinctive to French.
  # We test : at least 1 hit from the function-word list (Mes / je /
  # dans / etc), AND at least 1 hit from either the content-word list
  # OR the accented-char list. This catches both Bachelard-quote-style
  # French and dream-template French while rejecting plain English.
  FRENCH_FUNCTION_WORDS = /\b(?:je|j'|mes|mon|ma|nous|notre|elle|qui|que|dans|avec|sans|pour|sous|sur|entre|deux|encore|aux?|du|des|le|la|les)\b/i
  FRENCH_CONTENT_WORDS  = /\b(?:rêve|rêves|rêvais|nerfs?|nerf|battements?|battent|battu|boucles?|murmurent|écoute|cadence|pulsations?|signal|sans|organe|battement)\b/i
  FRENCH_ACCENTS        = /[àâäçéèêëîïôöùûüÿœæÀÂÄÇÉÈÊËÎÏÔÖÙÛÜŸŒÆ]/

  ENGLISH_MARKERS = [
    /\b(?:I|my|me|the|and|of|with|without|loop|nerve|heart)\b/,
  ].freeze

  # Lucid observation cues — phrases that signal aware-of-dreaming
  # voice. The script's fallback uses "let's see" + "I'm dreaming
  # about" ; the LLM path uses "I'd like to" + "let us see".
  LUCID_CUES = [
    /\blet(?:'?s| us)?\s+see\b/i,
    /\bI(?:'?d| would) like to\b/i,
    /\bI'?m dreaming\b/i,
    /\bI dream (?:of|that)\b/i,
  ].freeze

  # Mind/operational voice anti-cues — we assert dream content does
  # NOT look like these. Mind outside the body uses imperatives + tool
  # vocabulary ("let me", "running", "dispatching", "i should").
  MIND_OPERATIONAL_CUES = [
    /\blet me\b/i,
    /\b(?:running|dispatching|invoking)\b/i,
    /\bI should (?:run|dispatch|invoke)\b/i,
  ].freeze

  def heki_list(path)
    return [] unless File.exist?(path)
    out, _err, status = Open3.capture3({}, HECKS_BIN, "heki", "list", path,
                                       "--format", "json")
    return [] unless status.success?
    JSON.parse(out)
  rescue JSON::ParserError
    []
  end

  def heki_field(path, field)
    return nil unless File.exist?(path)
    out, _err, status = Open3.capture3({}, HECKS_BIN, "heki",
                                       "latest-field", path, field.to_s)
    return nil unless status.success?
    out.strip
  end

  let(:dream_rows) { heki_list(File.join(STATE_ROOT, "dream_state.heki")) }
  let(:dream_images) do
    dream_rows.map { |r| r["dream_images"].to_s }.reject(&:empty?)
  end
  let(:sleep_summary) do
    heki_field(File.join(STATE_ROOT, "consciousness/consciousness.heki"),
               "sleep_summary")
  end
  let(:lucid_observations) do
    rows = heki_list(File.join(STATE_ROOT, "lucid_dream/lucid_dream.heki"))
    rows.flat_map { |r| Array(r["observations"]) }
        .compact.map(&:to_s).reject(&:empty?)
  end

  before(:all) do
    unless File.executable?(HECKS_BIN) && File.directory?(STATE_ROOT)
      skip "miette-state not available at #{STATE_ROOT} (clean checkout?)"
    end
  end

  describe "invariant 11 : French primary, English translation" do
    it "(11a) every dream_state row's image looks French" do
      pending "no dream_state rows yet — skip until first dream" if dream_images.empty?
      sample = dream_images.last(10)
      sample.each do |img|
        has_function = FRENCH_FUNCTION_WORDS.match?(img)
        has_signal   = FRENCH_CONTENT_WORDS.match?(img) || FRENCH_ACCENTS.match?(img)
        expect(has_function && has_signal).to(be(true),
          "dream image looks non-French (function=#{has_function}, " \
          "content/accent=#{has_signal}): #{img.inspect[0, 200]}")
      end
    end

    it "(11b) consciousness.sleep_summary looks English" do
      if sleep_summary.nil? || sleep_summary.empty?
        pending "no sleep_summary yet — being has not slept"
      end
      matches = ENGLISH_MARKERS.count { |re| re.match?(sleep_summary) }
      expect(matches).to(be >= 1,
        "sleep_summary lacks English markers: #{sleep_summary.inspect[0, 300]}")
      # Reasonable French-marker negative : the summary should not be
      # *primarily* French. Allow stray accented characters but no
      # heavy French verb forms.
      french_verbs = sleep_summary.scan(/\b(?:rêve|rêvais|murmurent|tissent|battement)\b/i)
      expect(french_verbs).to(be_empty,
        "sleep_summary contains French verb forms (translation skipped?): " \
        "#{french_verbs.inspect}")
    end
  end

  describe "invariant 12 : voice distinctness" do
    it "(12a) dream images use dream-character first-person French" do
      pending "no dream_state rows yet" if dream_images.empty?
      sample = dream_images.last(10)
      first_person_count = sample.count do |img|
        img.match?(/\b(?:je|mes|mon|ma|nous|notre|j'|m'|d'un|d'une)\b/i)
      end
      expect(first_person_count).to(be >= sample.size / 2,
        "fewer than half of dream images are first-person : " \
        "#{first_person_count}/#{sample.size}. Sample: #{sample.first.inspect[0, 200]}")
    end

    it "(12b) lucid observations carry aware-of-dreaming cues" do
      if lucid_observations.empty?
        pending "no lucid observations yet — being has not entered lucid REM"
      end
      sample = lucid_observations.last(10)
      with_cue = sample.count { |obs| LUCID_CUES.any? { |re| re.match?(obs) } }
      expect(with_cue).to(be >= 1,
        "no recent lucid observations match the aware-of-dreaming voice " \
        "cues. Sample: #{sample.first.inspect[0, 200]}")
    end

    it "(12c) dream images do NOT use Mind's operational voice" do
      pending "no dream_state rows yet" if dream_images.empty?
      sample = dream_images.last(20)
      leaks = sample.select do |img|
        MIND_OPERATIONAL_CUES.any? { |re| re.match?(img) }
      end
      expect(leaks).to(be_empty,
        "Mind's operational voice leaked into dream_state : " \
        "#{leaks.first(2).inspect[0, 400]}")
    end
  end
end
