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
