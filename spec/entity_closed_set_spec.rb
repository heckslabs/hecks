require "spec_helper"
require "hecks/fuzzing/value_generator"

# A type-position `one_of` on an ENTITY attribute synthesizes a closed-set
# value object — and EntityBuilder used to build it and then drop it:
# `Entity.declare` carries no value objects, so the set existed nowhere in
# the finished graph. The attribute stayed typed at a name nothing could
# resolve — the one_of was decorative at runtime (no admission), and the
# fuzzer crashed every run on the first domain to declare one (a chess
# King/Rook's own castling flag) with `ValueGenerator does not know
# primitive type "Moved"`. The set now rides the same installer an
# entity's own identity value object already rides to the aggregate.
RSpec.describe "an entity attribute's own one_of" do
  def build_chapter(&block)
    registry = Hecks::Runtime::Registry.new
    built = nil
    Hecks.with_registry(registry) { built = Hecks.bluebook("EntityOneOf", &block) }
    built
  end

  def chapter_with_flagged_pieces
    build_chapter do
      vision "Pieces carrying their own closed-set flag, synthesized from a type-position one_of."
      supporting

      aggregate "Board" do
        description "A board of flagged pieces."

        attribute :name, BoardName
        identified_by :name
        attribute :pieces, list_of(Piece)

        value_object("BoardName") { attribute :value, String }
        value_object("PieceId")   { attribute :value, String }

        entity "Piece" do
          description "One piece, with a two-state flag of its own."

          attribute :id,   PieceId
          attribute :flag, one_of("up", "down")

          identified_by :id
        end

        entity "Marker" do
          description "A sibling piece synthesizing the IDENTICAL set — installed once, not twice."

          attribute :id,   PieceId
          attribute :flag, one_of("up", "down")

          identified_by :id
        end
      end
    end
  end

  it "lands the synthesized closed set on the aggregate, where the runtime and the IR can both reach it" do
    board = chapter_with_flagged_pieces.aggregate("Board")
    flag  = board.value_object("Flag")

    expect(flag).not_to be_nil
    expect(flag.closed_set?).to be(true)
    expect(flag.members.map { |m| m.to_h[:value].to_s }).to contain_exactly("up", "down")
  end

  it "installs an identical sibling set once — King's and Rook's own `moved` are one Moved" do
    board = chapter_with_flagged_pieces.aggregate("Board")

    expect(board.value_objects.count { |vo| vo.hecks_name == "Flag" }).to eq(1)
  end

  it "feeds the fuzzer a real member instead of crashing on an unknown primitive" do
    board = chapter_with_flagged_pieces.aggregate("Board")
    piece = board.entities.find { |e| e.hecks_name == "Piece" }
    flag  = piece.attributes.find { |a| a.name.to_s == "flag" }

    value = Hecks::Fuzzing::ValueGenerator.value_for(flag, board, random: Random.new(1))
    scalar = Hecks::Fuzzing::ValueGenerator.scalar_of(value)
    # A generated value is USUALLY an admitted member; the generator also
    # deliberately mints invalid ones to exercise the refusal. Either way
    # it must answer, never raise "does not know primitive type".
    expect(scalar).to be_a(String)
  end

  it "refuses two pieces synthesizing the SAME name with DIFFERENT members — a collision, never first-wins" do
    expect do
      build_chapter do
        vision "Two pieces disagreeing about what Flag admits."
        supporting

        aggregate "Board" do
          description "A board whose pieces disagree."

          attribute :name, BoardName
          identified_by :name

          value_object("BoardName") { attribute :value, String }
          value_object("PieceId")   { attribute :value, String }

          entity "Piece" do
            description "Flag as up/down."
            attribute :id,   PieceId
            attribute :flag, one_of("up", "down")
            identified_by :id
          end

          entity "Marker" do
            description "Flag as left/right — not the same set at all."
            attribute :id,   PieceId
            attribute :flag, one_of("left", "right")
            identified_by :id
          end
        end
      end
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /already holds a different "Flag"/)
  end
end
