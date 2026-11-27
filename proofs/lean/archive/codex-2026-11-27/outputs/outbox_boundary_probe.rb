require "json"
require "tmpdir"
require "fileutils"
require "hecks"

Dir.mktmpdir("crystal-outbox-") do |sandbox|
  File.write(File.join(sandbox, "shop.bluebook"), <<~BLUEBOOK)
    Hecks.bluebook "Shop" do
      vision "An order placed is recorded by a reaction."
      core
      aggregate "Order" do
        value_object("Number") { attribute :value, String }
        attribute :number, Number
        identified_by :number
        command "Place" do
          attribute :number, Number
          sets :number
          emits "OrderPlaced"
        end
      end
      aggregate "Ledger" do
        value_object("Number") { attribute :value, String }
        attribute :number, Number
        identified_by :number
        command "Record" do
          attribute :number, Number
          given("deliberate refusal") { false }
          sets :number
          emits "OrderRecorded"
        end
      end
      policy "RecordOrder" do
        on "OrderPlaced"
        trigger Ledger::Record, with: { number: :number }
      end
    end
  BLUEBOOK
  File.write(File.join(sandbox, "shop.hecksagon"), <<~HECKSAGON)
    Hecks.hecksagon "Shop" do
      persisted_by "Memory"
    end
  HECKSAGON
  runtime = Hecks.boot(sandbox)
  result = runtime.dispatch_flat("Shop::Order.Place", number: { value: "o-1" })
  first = { command: "success", order: result.instance.state,
            events: runtime.events.map(&:name), reactions: runtime.reactions,
            outbox_rows: runtime.outbox.rows.map { |row| { status: row.status, consumer: row.consumer, error: row.error } } }
  runtime.outbox.define_singleton_method(:run_consumer) { |*| raise "consumer exploded" }
  second = runtime.dispatch_flat("Shop::Order.Place", number: { value: "o-2" })
  failed_delivery = { command: "success", order: second.instance.state,
                      outbox_rows: runtime.outbox.rows.map { |row| { status: row.status, error: row.error } } }
  raise "refused reaction changed primary result" unless first[:command] == "success" &&
    first[:outbox_rows].map { |row| row[:status] } == ["refused"]
  raise "failed reaction changed primary result" unless failed_delivery[:command] == "success" &&
    failed_delivery[:outbox_rows].map { |row| row[:status] } == ["refused", "failed"]
  puts JSON.pretty_generate({
    refused_reaction: first,
    failed_reaction: failed_delivery
  })
end
