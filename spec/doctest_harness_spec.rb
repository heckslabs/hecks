require "spec_helper"
require_relative "support/doctest"
require "tempfile"

# The doctest harness, proven on itself before any guide trusts it. The
# one that matters most is the LINE-MAPPING case: a failing claim must
# name the guide's true line, or every future failure sends its reader
# to the wrong paragraph.
RSpec.describe Doctest do
  def guide(markdown)
    file = Tempfile.new(["doctest-guide-", ".md"])
    file.write(markdown)
    file.flush
    @guides << file
    file.path
  end

  before { @guides = [] }
  after  { @guides.each(&:close!) }

  it "runs a whole guide — declarations, wiring, shared locals, claims, refusals" do
    path = guide(<<~MD)
      # A tiny guide

      ```ruby bluebook
      Hecks.bluebook "DoctestSampleA" do
        vision "A guide's own tiny domain."
        generic

        aggregate "DoctestGadget" do
          description "A widget."
          identified_by :name

          attribute :name, Name

          value_object "Name" do
            attribute :value, String
          end

          lifecycle :status, default: "current" do
            transition "Retire" => "retired", from: "current"
          end

          command "Add" do
            attribute :name, Name
            emits "WidgetAdded"
          end

          command "Retire" do
            reference_to DoctestGadget
            given("only a current widget retires") { status == "current" }
            emits "WidgetRetired"
          end
        end
      end
      ```

      ```ruby boot
      Hecks.hecksagon("DoctestSampleA") { DoctestSampleA::DoctestGadget.persisted_by("Memory") }
      ```

      Locals carry across blocks:

      ```ruby
      widget = DoctestGadget.add!(name: { value: "w1" })
      widget.status   # => "current"
      ```

      ```ruby
      widget.retire!
      widget.status   # => "retired"
      widget.retire!   # ~> GivenNotMet: only a current widget retires
      ```

      ```ruby skip
      this does not even parse — and is never asked to
      ```
    MD

    expect(Doctest.run(path)).to be(true)
  end

  it "names the guide's TRUE line when a claim fails" do
    path = guide(<<~MD)
      # prose line one
      # prose line two

      ```ruby
      answer = 1 + 1
      answer   # => 3
      ```
    MD

    expect { Doctest.run(path) }.to raise_error(Doctest::Mismatch) { |error|
      expect(error.message).to include("#{path}:6")
      expect(error.message).to include("expected: 3").and include("actual:   2")
    }
  end

  it "fails a refusal claim whose expression declines to refuse" do
    path = guide(<<~MD)
      ```ruby
      1 + 1   # ~> ArgumentError: anything
      ```
    MD

    expect { Doctest.run(path) }
      .to raise_error(Doctest::Mismatch, /no refusal at all/)
  end

  it "passes a refusal claim on class and message together" do
    path = guide(<<~MD)
      ```ruby
      Integer("nope")   # ~> ArgumentError: invalid value for Integer
      ```
    MD

    expect(Doctest.run(path)).to be(true)
  end

  it "runs a later declaration block as a second wave, its own boot" do
    path = guide(<<~MD)
      ```ruby
      x = 41
      ```

      ```ruby bluebook
      Hecks.bluebook "DoctestWaveTwo" do
        vision "The second narrative in one file."
        generic

        aggregate "DoctestHarnessMemo" do
          description "A note."
          identified_by :label

          attribute :label, Label

          value_object "Label" do
            attribute :value, String
          end

          command "Jot" do
            attribute :label, Label
            emits "Jotted"
          end
        end
      end
      ```

      ```ruby boot
      Hecks.hecksagon("DoctestWaveTwo") { DoctestWaveTwo::DoctestHarnessMemo.persisted_by("Memory") }
      ```

      ```ruby
      x + 1                                     # => 42
      DoctestHarnessMemo.jot!(label: { value: "later" }).label.to_h   # => { value: "later" }
      ```
    MD

    expect(Doctest.run(path)).to be(true)
  end

  it "refuses a claim marker on a line that does not parse alone" do
    path = guide(<<~MD)
      ```ruby
      [1, 2,
       3].size   # => 3
      ```
    MD

    expect { Doctest.run(path) }
      .to raise_error(Doctest::Malformed, /single-line expression/)
  end

  it "passes a guide with nothing to run" do
    expect(Doctest.run(guide("# just prose\n\nno fences at all\n"))).to be(true)
  end

  it "reads declared domains and the postgres pragma" do
    path = guide(<<~MD)
      <!-- doctest: postgres -->

      ```ruby bluebook
      Hecks.bluebook "DoctestSampleB" do
      end
      ```

      ```ruby boot
      Hecks.hecksagon("DoctestSampleB") { DoctestSampleB::Thing.persisted_by("Memory") }
      Hecks.world("DoctestWorldB") { realm "Examples" }
      ```
    MD

    parsed = Doctest.parse(path)
    expect(parsed.postgres).to be(true)
    # Only the fresh `Hecks.bluebook` invention counts as OWNED — the
    # hecksagon/world block wires an already-declared chapter and is not
    # itself an invented name (see declared_domains' own comment).
    expect(Doctest.declared_domains(parsed)).to contain_exactly("DoctestSampleB")
  end
end
