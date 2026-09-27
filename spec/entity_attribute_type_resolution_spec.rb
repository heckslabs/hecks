require "spec_helper"
require "tmpdir"

# An entity attribute's type resolves as a reference to a ValueObject, as on Aggregate.
# A nested piece routes through the "Holds" command instead of that check.
RSpec.describe "an entity's attribute types" do
  def boot_bluebook(source)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "repro.bluebook"), source)
      Hecks.boot(dir)
    end
  end

  # The fixture stays inline: it is the literal source Prism reads.
  # rubocop:disable-next RSpec/ExampleLength
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

  # rubocop:disable-next RSpec/ExampleLength
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
