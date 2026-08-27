require "spec_helper"
require "tmpdir"

# M13 — an entity's attribute types are never resolved as references.
#
# Aggregate.Attribute types its `type` argument `reference_to ValueObject` —
# "attributes must use value-object types" is enforced by reference
# resolution, not a predicate (that command's own comment). Entity.Attribute
# carried the identical field as plain text, so an entity attribute naming an
# undeclared value object — a typo, or a type that was never declared at all —
# built clean. `entity.bluebook`'s own "Attribute" command now carries the
# same `reference_to ValueObject, as: :type` Aggregate's does, and an entity
# attribute whose type names a nested piece routes through a new "Holds"
# command (mirroring Aggregate.Holds) rather than falling through to the same
# ValueObject-reference check a plain attribute uses.
RSpec.describe "an entity's attribute types" do
  def boot_bluebook(source)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "repro.bluebook"), source)
      Hecks.boot(dir)
    end
  end

  it "refuses an entity attribute naming an undeclared value object" do
    source = <<~BLUEBOOK
      Hecks.bluebook "Repro" do
        vision "a piece attribute naming nothing real"
        supporting

        aggregate "Widget" do
          description "a widget"
          identified_by :label
          attribute :label, Label

          value_object "Label" do
            attribute :value, String
          end

          entity "Piece" do
            description "a piece of the widget"
            identified_by :label
            attribute :label, Label
            # NEVER DECLARED — no value_object named Bogus exists anywhere
            # on Widget. This must be refused, not boot clean.
            attribute :ghost, Bogus

            command "Touch" do
              role "Someone"
              goal "touch the piece"
              sets :label
              emits "PieceTouched"
            end
          end

          command "Make" do
            role "Someone"
            goal "make a widget"
            attribute :label, Label
            sets :label
            emits "WidgetMade"
          end
        end
      end
    BLUEBOOK

    expect { boot_bluebook(source) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /no ValueObject with aggregate, name .*Bogus/)
  end

  it "accepts an entity attribute naming a value object its own aggregate declares" do
    source = <<~BLUEBOOK
      Hecks.bluebook "Repro" do
        vision "a piece attribute naming a real value object"
        supporting

        aggregate "Widget" do
          description "a widget"
          identified_by :label
          attribute :label, Label

          value_object "Label" do
            attribute :value, String
          end

          entity "Piece" do
            description "a piece of the widget"
            identified_by :label
            attribute :label, Label

            command "Touch" do
              role "Someone"
              goal "touch the piece"
              sets :label
              emits "PieceTouched"
            end
          end

          command "Make" do
            role "Someone"
            goal "make a widget"
            attribute :label, Label
            sets :label
            emits "WidgetMade"
          end
        end
      end
    BLUEBOOK

    expect { boot_bluebook(source) }.not_to raise_error
  end
end
