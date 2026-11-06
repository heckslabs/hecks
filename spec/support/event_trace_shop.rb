# frozen_string_literal: true

require "json"
require "fileutils"

# A disposable domain for the event trace specs: placing an order owes the ledger a record (it
# delivers) and a rehearsal whose `with:` reads a key the event leaves out (it is refused); touching
# or archiving an order has no listener or none that has fired; pinging an order answers itself
# until the reaction depth is reached.
module EventTraceShop
  BLUEBOOK = <<~RUBY
    Hecks.bluebook "Trace" do
      vision "Orders placed are recorded."

      aggregate "Order" do
        attribute :number, Number
        identified_by :number
        value_object("Number") { attribute :value, String }

        command("Place")   { attribute :number, Number; attribute :checkout, String, optional: true; sets :number; emits "OrderPlaced" }
        command("Touch")   { reference_to Order; emits "OrderTouched" }
        command("Archive") { reference_to Order; emits "OrderArchived" }
        command("Ping")    { reference_to Order; emits "OrderPinged" }
      end

      aggregate "Ledger" do
        attribute :number, Number
        identified_by :number
        value_object("Number") { attribute :value, String }

        command("Record")   { attribute :number, Number; sets :number; emits "OrderRecorded" }
        command("Rehearse") { attribute :checkout, String; emits "OrderRehearsed" }
      end

      policy("RecordOrder")   { on "OrderPlaced"; trigger Ledger::Record, with: { number: :number } }
      policy("RehearseOrder") { on "OrderPlaced"; trigger Ledger::Rehearse, with: { checkout: :checkout } }
      policy("ShelveOrder")   { on "OrderArchived"; trigger Ledger::Record, with: { number: :id } }
      policy("PingAgain")     { on "OrderPinged"; trigger Order::Ping, with: { order: :id } }
    end
  RUBY

  module_function

  # Writes the domain into `dir`; `adapter` and `world` wire its persistence, nil leaves Memory.
  def write(dir, adapter: nil, world: nil)
    FileUtils.mkdir_p(File.join(dir, "bluebook"))
    File.write(File.join(dir, "bluebook/trace.bluebook"), BLUEBOOK)
    return unless adapter

    File.write(File.join(dir, "bluebook/trace.hecksagon"),
               %(Hecks.hecksagon "Trace" do\n  #{"revisions true\n  " if adapter == "Postgres"}persisted_by "#{adapter}"\nend\n))
    File.write(File.join(dir, "bluebook/trace.world"), world)
  end

  def sqlite_world(path)
    %(Hecks.world "Trace" do\n  persisted_by("SqlitePersistence") { database "#{path}" }\nend\n)
  end

  def postgres_world(database)
    settings = %W[database\ "#{database}" disposable_ledger\ true allow_superuser\ true].join("\n    ")
    %(Hecks.world "Trace" do\n  persisted_by("Postgres") do\n    #{settings}\n  end\nend\n)
  end

  # Boots the domain in `dir` and places and touches an order.
  def run(dir)
    runtime = Hecks.boot(File.join(dir, "bluebook"), install_driving: false)
    runtime.dispatch("Trace::Order.Place", with: { number: { value: "o-1" } })
    runtime.dispatch("Trace::Order.Touch", to: "o-1")
    runtime
  end

  # The trace as a hash.
  def trace(dir, **args)
    JSON.parse(Hecks::Adapters::JournalStore.new.event_trace(domain: dir, **args)[:text], symbolize_names: true)
  end

  # [event name, consumer, outcome] for every listener of every traced event.
  def outcomes(report)
    report[:events].flat_map { |row| row[:subscribers].map { |sub| [row[:event][:name], sub[:consumer], sub[:outcome]] } }
  end
end
