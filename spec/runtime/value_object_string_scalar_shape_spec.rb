require "spec_helper"
require "hecks/fuzzing"

# Pins that a non-string scalar (Integer, Float, Boolean) for a String-typed value-object
# field is refused with TypeMismatch on that field first, as Rust's `from_json` does.
#
# `Value::Coercion.judge_bootstrapping?` exempts only `MetaValidator::Judge#send_to`, whose
# self-judging of the grammar hands the "position" field a raw Integer on every first boot;
# every boot in the suite exercises that exemption.
RSpec.describe "QualityControl BUG#125 — value-object String scalar-shape tightening" do
  describe "a value object refuses a non-string scalar for a String-typed field" do
    let(:domain) { File.join(InMemoryDomain::ROOT, "examples/chess") }

    # Replays one capture of a piece and answers the refusal it provoked, if any.
    def capture_refusal(id, by_value)
      steps = [{ "verb" => "Chess::Game.Piece.Capture", "args" => { "id" => id, "by" => { "value" => by_value } } }]
      Hecks::Fuzzing::Replay.call(domain, steps)[:refusals].find { |r| r[:verb] == "Chess::Game.Piece.Capture" }
    end

    def expect_piece_id_type_mismatch(id)
      refusal = capture_refusal(id, "white")
      expect(refusal).not_to be_nil, "expected a refusal for id: #{id.inspect}"
      expect(refusal).to include(kind: "Hecks::Runtime::TypeMismatch", error: a_string_including("PieceId.value expects String"))
    end

    it "refuses TypeMismatch on PieceId.value immediately, never reaching the by:Color check", :aggregate_failures do
      refusal = capture_refusal(-1_267_650_600_228_229_401_496_703_205_376, "india delta")

      expect(refusal).not_to be_nil
      expect(refusal[:kind]).to eq("Hecks::Runtime::TypeMismatch")
      expect(refusal[:error]).to include("PieceId.value expects String")
      expect(refusal[:error]).not_to include("Color")
    end

    it "still refuses TypeMismatch on PieceId.value for a plain Float or a Boolean" do
      [3.5, true, false].each { |bad_id| expect_piece_id_type_mismatch(bad_id) }
    end

    it "still refuses an Array/Hash standing in for a String-typed field, unchanged" do
      expect_piece_id_type_mismatch([1, 2])
    end

    it "still admits a genuine String id (fails later, for an unrelated reason — no game exists)", :aggregate_failures do
      refusal = capture_refusal("p1", "white")

      expect(refusal).not_to be_nil
      expect(refusal[:error]).not_to include("PieceId")
    end
  end
end
