require "spec_helper"
require "hecks/bluebook/model_check"
require "tempfile"

# model_check's `forwarded_payload` warning: a policy with no `with:` hands its trigger the whole
# event, and a required event field the target command does not take refuses every reaction.
RSpec.describe "model_check over forwarded payloads" do
  let(:files) { [chapter_file(stock_bluebook), chapter_file(stock_hecksagon)] }
  let(:findings) { Hecks::Bluebook::ModelCheck.call(stock) }
  let(:forwarded) { findings.select { |finding| finding.kind == :forwarded_payload } }

  after { files.each(&:close!) }

  def chapter_file(source)
    Tempfile.new(["stock", ".rb"]).tap do |file|
      file.write(source)
      file.flush
    end
  end

  def stock
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, *files.map(&:path)].each { |path| Kernel.load(path) }
    end
    registry.bluebook("Stock")
  end

  # `LotRegraded` always carries `grade`, which `Check` does not take; `LotAnnotated` carries only
  # the lot and an optional note, so `CheckWhenAnnotated` can deliver.
  def stock_bluebook
    <<~RUBY
      Hecks.bluebook "Stock" do
        vision "Lots whose grade moves, for the forwarded-payload check."
        core

        aggregate "Lot" do
          description "A lot of stock."
          identified_by :number
          attribute :number, LotNumber
          attribute :grade, Grade

          value_object("LotNumber") { attribute :value, String }
          value_object("Grade") { attribute :value, Integer }
          value_object("Note") { attribute :value, String }

          command "Receive" do
            goal "Receive a lot"
            attribute :number, LotNumber
            attribute :grade, Grade
            sets :number
            sets :grade
            emits "LotReceived"
          end

          command "Regrade" do
            goal "Move a lot's grade"
            reference_to Lot
            attribute :grade, Grade
            sets :grade
            emits "LotRegraded"
          end

          command "Annotate" do
            goal "Note something about a lot"
            reference_to Lot
            attribute :note, Note, optional: true
            emits "LotAnnotated"
          end

          command "Check" do
            goal "Check a lot"
            reference_to Lot
            emits "LotChecked"
          end
        end

        policy "CheckWhenRegraded" do
          on Lot::LotRegraded
          trigger Lot::Check
        end

        policy "CheckWhenRegradedNamingTheLot" do
          on Lot::LotRegraded
          trigger Lot::Check, with: { lot: :number }
        end

        policy "CheckWhenAnnotated" do
          on Lot::LotAnnotated
          trigger Lot::Check
        end
      end
    RUBY
  end

  def stock_hecksagon
    <<~RUBY
      Hecks.hecksagon "Stock" do
        Stock::Lot.persisted_by("Memory")
      end
    RUBY
  end

  it "warns on a trigger with no with: that is always given a field it does not take" do
    expect(forwarded.map { |finding| [finding.severity, finding.subject] }).to eq([[:warning, "CheckWhenRegraded"]])
  end

  it "names the trigger, the event and the field the trigger does not take" do
    expect(forwarded.first.message).to include("Lot.Check is given Lot.LotRegraded whole", "does not take :grade")
  end

  it "does not judge a trigger that names what it takes with with:" do
    expect(forwarded.map(&:subject)).not_to include("CheckWhenRegradedNamingTheLot")
  end

  it "counts neither an optional event field nor the target's own reference key" do
    expect(forwarded.map(&:subject)).not_to include("CheckWhenAnnotated")
  end

  it "is a warning, so a chapter that keeps such a policy on purpose still has no errors" do
    expect(findings.select { |finding| finding.severity == :error }).to be_empty
  end
end
