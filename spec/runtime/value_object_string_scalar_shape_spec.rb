require "spec_helper"
require "hecks/fuzzing"

# QualityControl BUG#125 — `Value::Coercion#check_scalar_shapes` used to
# tolerate any non-composite scalar (Integer, Float, true/false) for a
# String-typed value-object field, refusing only Array/Hash. Rust's
# generated `from_json` requires a JSON string node for a String-typed
# field unconditionally, refusing anything else immediately. The gap: a
# command whose declared arguments are each independently invalid in
# different ways diverged on refusal kind, not just wording — Ruby's
# leniency let a bad `id` sail past its own check and fail later on an
# unrelated field, while Rust refused on `id` first.
#
# `Chess::Game.Piece.Capture`'s own `id` (PieceId, String-typed) offered a
# bignum, alongside `by` (Color, closed-set) offered a value outside its
# `one_of` set — found live via `bin/qa_sweep chess`
# (tmp/qa-shrunk/SW-chess-1789342745-differential.json), pinned here.
#
# The fix is narrowly scoped: `Value::Coercion.judge_bootstrapping?`
# (coercion.rb) exempts only `MetaValidator::Judge#send_to` — the choke
# point every one of the language's own self-hosted grammar dispatches
# goes through while walking a bluebook's declarations into the
# "Bluebook" meta-domain. `Judge#appends`' generic walk-index handling
# for any field literally named "position" collides with
# `NormalisationRule`/`Normalise`'s own domain field of the same name,
# which is `RuleText` (String) rather than the `Position` (Integer) type
# every other "position" field in the language's grammar uses — so
# `Judge#v(index)` hands that one field a raw Integer, on every domain's
# first boot (the language self-judges its own grammar). The record this
# produces is provably never read back (`normalisations` is spliced
# straight from `Expression::CanonicalForm.table`, an elsewhere/derived
# field — assembly/contracts.rb) — a walk-index/domain-field name
# collision inside Judge, not a genuine semantic need for `position` to
# arrive numeric — but unexempted, this does break every domain's boot
# today (`MetaValidator.call` raises the instant a judge's refusals are
# non-empty). Every boot in the suite — the chess replays below included —
# exercises that exemption, so an ordinary domain booting clean needs no
# example of its own here.
RSpec.describe "QualityControl BUG#125 — value-object String scalar-shape tightening" do
  describe "a value object refuses a non-string scalar for a String-typed field" do
    let(:domain) { File.join(InMemoryDomain::ROOT, "examples/chess") }

    it "refuses TypeMismatch on PieceId.value immediately, never reaching the by:Color check" do
      steps = [
        {
          "verb" => "Chess::Game.Piece.Capture",
          "args" => { "id" => -1_267_650_600_228_229_401_496_703_205_376, "by" => { "value" => "india delta" } }
        }
      ]
      result = Hecks::Fuzzing::Replay.call(domain, steps)

      refusal = result[:refusals].find { |r| r[:verb] == "Chess::Game.Piece.Capture" }
      expect(refusal).not_to be_nil
      expect(refusal[:kind]).to eq("Hecks::Runtime::TypeMismatch")
      expect(refusal[:error]).to include("PieceId.value expects String")
      expect(refusal[:error]).not_to include("Color")
    end

    it "still refuses TypeMismatch on PieceId.value for a plain Float or a Boolean" do
      [3.5, true, false].each do |bad_id|
        steps = [{ "verb" => "Chess::Game.Piece.Capture", "args" => { "id" => bad_id, "by" => { "value" => "white" } } }]
        result = Hecks::Fuzzing::Replay.call(domain, steps)

        refusal = result[:refusals].find { |r| r[:verb] == "Chess::Game.Piece.Capture" }
        expect(refusal).not_to be_nil, "expected a refusal for id: #{bad_id.inspect}"
        expect(refusal[:kind]).to eq("Hecks::Runtime::TypeMismatch")
        expect(refusal[:error]).to include("PieceId.value expects String")
      end
    end

    it "still refuses an Array/Hash standing in for a String-typed field, unchanged" do
      steps = [{ "verb" => "Chess::Game.Piece.Capture", "args" => { "id" => [1, 2], "by" => { "value" => "white" } } }]
      result = Hecks::Fuzzing::Replay.call(domain, steps)

      refusal = result[:refusals].find { |r| r[:verb] == "Chess::Game.Piece.Capture" }
      expect(refusal).not_to be_nil
      expect(refusal[:kind]).to eq("Hecks::Runtime::TypeMismatch")
      expect(refusal[:error]).to include("PieceId.value expects String")
    end

    it "still admits a genuine String id (fails later, for an unrelated reason — no game exists)" do
      steps = [{ "verb" => "Chess::Game.Piece.Capture", "args" => { "id" => "p1", "by" => { "value" => "white" } } }]
      result = Hecks::Fuzzing::Replay.call(domain, steps)

      refusal = result[:refusals].find { |r| r[:verb] == "Chess::Game.Piece.Capture" }
      expect(refusal).not_to be_nil
      expect(refusal[:error]).not_to include("PieceId")
    end
  end
end
