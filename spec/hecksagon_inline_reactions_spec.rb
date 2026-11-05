require "spec_helper"
require "tmpdir"

# Reactions on an adapter with no outbox refuse to boot unless the hecksagon says
# `inline_reactions true` (ADR 0182).
RSpec.describe "inline_reactions, the hecksagon word that accepts in-process reactions" do
  def bluebook_text
    <<~RUBY
      Hecks.bluebook "Shop" do
        vision "Sell and record orders."
        supporting

        aggregate "Order" do
          description "A customer's order."
          attribute :number, Number
          identified_by :number

          value_object("Number") { attribute :value, String }

          command "Place" do
            attribute :number, Number
            sets :number
            emits "OrderPlaced"
          end
        end

        aggregate "Ledger" do
          description "The record of placed orders."
          attribute :number, Number
          identified_by :number

          value_object("Number") { attribute :value, String }

          command "Record" do
            attribute :number, Number
            sets :number
            emits "OrderRecorded"
          end
        end

        policy "RecordOrder" do
          on "OrderPlaced"
          trigger Ledger::Record, with: { number: :number }
        end
      end
    RUBY
  end

  # Boots the Shop domain on Heki, which has no outbox, with `wiring` added to its hecksagon.
  def boot_on_heki(wiring)
    Dir.mktmpdir("inline-reactions") do |dir|
      File.write(File.join(dir, "shop.bluebook"), bluebook_text)
      File.write(File.join(dir, "shop.hecksagon"),
                 "Hecks.hecksagon \"Shop\" do\n  Shop::Order.persisted_by(\"Heki\")\n  Shop::Ledger.persisted_by(\"Heki\")\n#{wiring}\nend\n")
      Hecks.boot(dir, install_driving: false)
    end
  end

  it "records the word on the hecksagon" do
    expect(boot_on_heki("  inline_reactions true").registry.hecksagon("Shop").inline_reactions?).to be true
  end

  it "refuses at boot a domain whose reactions would be lost on Heki" do
    expect { boot_on_heki("") }
      .to raise_error(Hecks::Runtime::WiringError, /Shop declares policies.*Heki.*inline_reactions true/)
  end

  it "boots a domain whose hecksagon accepts in-process reactions" do
    expect { boot_on_heki("  inline_reactions true") }.not_to raise_error
  end
end
