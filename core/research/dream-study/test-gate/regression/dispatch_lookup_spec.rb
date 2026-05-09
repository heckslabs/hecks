# dispatch_lookup_spec.rb
#
# [antibody-exempt: dream-study Phase 0f regression — covers named
#  bugs i189 + i203 + i204 ; retires once .behaviors runner can
#  drive Update commands by reference attribute]
#
# Regression coverage for i189, i203, i204 — the silent-fail bugs
# where Update-shape commands could not find their existing row.
#
# i189 : TickedFeature.Tick (and MarkLate, MarkFailed) declare no
#        reference attribute. Dispatch was classified as Create,
#        appending a new row per Tick instead of updating by name.
#        StatuslineSnapshot.Update has the same shape.
#
# i203 : Synapse.{Strengthen, Fire, Decay, Compost}Synapse dispatched
#        without a reference attribute — every dispatch failed
#        AggregateNotFound because nothing identified the target row.
#        Fix : `reference_to(Synapse)` on each Update command + the
#        runtime auto-populating storage uuid on every record.
#
# i204 : Signal.{Access, Archive}Signal — same shape as i203.
#
# Specs : seed by Create / heki_seed, dispatch the Update by id or
# name, assert the row's mutating field changed and no duplicate
# row appeared.

require_relative "spec_helper"

RSpec.describe "Dispatch lookup (i189, i203, i204)" do
  context "i189 — TickedFeature.Tick upserts by name (does not Create)" do
    let(:bluebook) { File.join(MIETTE_DIR, "surface/studio/studio.bluebook") }

    it "advances the heart row's last_tick_at without creating duplicates" do
      h = setup_harness("i189_tick")
      h.copy_bluebook(bluebook)

      3.times do |i|
        result = h.dispatch(
          "TickedFeature.Tick",
          name:         "heart",
          last_tick_at: "2026-05-01T00:00:0#{i}Z"
        )
        expect(result).to be_ok, "Tick #{i} failed: #{result.error_message}"
      end

      rows = h.heki_all("studio/ticked_feature.heki")
      expect(rows.size).to eq(1), "Tick produced #{rows.size} rows ; expected 1 upsert per name"

      row = rows.values.first
      expect(row["id"]).to           eq("heart")
      expect(row["last_tick_at"]).to eq("2026-05-01T00:00:02Z")
      expect(row["status"]).to       eq("running")
    end

    it "StatuslineSnapshot.Update upserts the singleton (does not append)" do
      h = setup_harness("i189_statusline")
      h.copy_bluebook(bluebook)

      3.times do |i|
        result = h.dispatch(
          "StatuslineSnapshot.Update",
          payload_json: %({"tick":#{i}}),
          updated_at:   "2026-05-01T00:00:0#{i}Z"
        )
        expect(result).to be_ok, "Update #{i} failed: #{result.error_message}"
      end

      rows = h.heki_all("studio/statusline_snapshot.heki")
      # FIXED 2026-05-02 : surface/studio/studio.bluebook now declares
      # identified_by :name with attribute :name default "statusline".
      # Update routes to the singleton slot ; three Updates produce one
      # row, not three.
      expect(rows.size).to eq(1), "i189 expected 1 singleton row, got #{rows.size}"

      row = rows.values.first
      expect(row["payload_json"]).to eq(%({"tick":2})), "expected last write to win"
      expect(row["updated_at"]).to   eq("2026-05-01T00:00:02Z")
    end
  end

  context "i203 — Synapse.StrengthenSynapse finds the existing row by id" do
    let(:bluebook) { File.join(MIETTE_DIR, "body/organs/synapse.bluebook") }

    it "increments firings + climbs strength on the seeded synapse" do
      h = setup_harness("i203_synapse")
      h.copy_bluebook(bluebook)

      created = h.dispatch(
        "Synapse.CreateSynapse",
        from: "carrying", to: "concept", strength: 0.1
      )
      expect(created).to be_ok, "CreateSynapse failed: #{created.error_message}"

      synapse_id = created.payload["id"]
      expect(synapse_id).not_to be_nil

      strengthened = h.dispatch("Synapse.StrengthenSynapse", synapse: synapse_id)
      expect(strengthened).to be_ok, "StrengthenSynapse failed: #{strengthened.error_message}"

      row = h.heki_latest("synapse/synapse.heki")
      expect(row["id"]).to eq(synapse_id)
      # Strength climbed from 0.1 to 0.12 (i106 in-DSL math).
      expect(row["strength"].to_f).to be_within(0.0001).of(0.12)
    end

    it "FireSynapse increments firings on the existing row" do
      h = setup_harness("i203_fire")
      h.copy_bluebook(bluebook)

      created = h.dispatch(
        "Synapse.CreateSynapse",
        from: "a", to: "b", strength: 0.5
      )
      synapse_id = created.payload["id"]

      fired = h.dispatch(
        "Synapse.FireSynapse",
        synapse:       synapse_id,
        last_fired_at: "2026-05-01T12:00:00Z"
      )
      expect(fired).to be_ok, "FireSynapse failed: #{fired.error_message}"

      row = h.heki_latest("synapse/synapse.heki")
      expect(row["firings"]).to       eq(1)
      expect(row["last_fired_at"]).to eq("2026-05-01T12:00:00Z")
    end
  end

  context "i204 — Signal.ArchiveSignal finds the existing row by id" do
    let(:bluebook) { File.join(MIETTE_DIR, "body/organs/signal.bluebook") }

    it "flips kind to archived on the seeded signal" do
      h = setup_harness("i204_signal")
      h.copy_bluebook(bluebook)

      fired = h.dispatch(
        "Signal.FireSignal",
        kind: "somatic", payload: "hello",
        strength: 0.5, created_at: "2026-05-01T12:00:00Z"
      )
      expect(fired).to be_ok, "FireSignal failed: #{fired.error_message}"
      signal_id = fired.payload["id"]

      archived = h.dispatch("Signal.ArchiveSignal", signal: signal_id)
      expect(archived).to be_ok, "ArchiveSignal failed: #{archived.error_message}"

      row = h.heki_latest("signal/signal.heki")
      expect(row["id"]).to   eq(signal_id)
      expect(row["kind"]).to eq("archived")
    end

    it "AccessSignal increments access_count" do
      h = setup_harness("i204_access")
      h.copy_bluebook(bluebook)

      fired = h.dispatch(
        "Signal.FireSignal",
        kind: "conceptual", payload: "x",
        strength: 0.3, created_at: "2026-05-01T12:00:00Z"
      )
      signal_id = fired.payload["id"]

      2.times do
        result = h.dispatch("Signal.AccessSignal", signal: signal_id)
        expect(result).to be_ok, "AccessSignal failed: #{result.error_message}"
      end

      row = h.heki_latest("signal/signal.heki")
      expect(row["access_count"]).to eq(2)
    end
  end
end
