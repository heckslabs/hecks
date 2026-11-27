require "json"
require "tmpdir"
require "fileutils"
require "hecks"

source = ENV.fetch("HECKS_SOURCE", "/Users/christopheryoung/Projects/hecks")
Dir.mktmpdir("crystal-outbox-sqlite-") do |sandbox|
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
    Kernel.load(#{File.join(source, "lib/hecks/adapters/driven/sqlite.adapter").inspect})
    Hecks.hecksagon "Shop" do
      persisted_by "SqlitePersistence"
    end
  HECKSAGON
  File.write(File.join(sandbox, "shop.world"), <<~WORLD)
    Hecks.world "Shop" do
      persisted_by("SqlitePersistence") { database(#{File.join(sandbox, "shop.db").inspect}) }
    end
  WORLD

  runtime = Hecks.boot(sandbox)
  runtime.outbox.define_singleton_method(:deliver) { |*| raise Interrupt, "crash before claim" }
  crash = nil
  begin
    runtime.dispatch_flat("Shop::Order.Place", number: { value: "o-1" })
  rescue Interrupt => e
    crash = e.message
  end
  order = runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Order"))
  after_crash = { crash: crash, stored_order: !order.find("o-1").nil?,
                  events: runtime.events.map(&:name),
                  outbox: runtime.outbox.rows.map(&:status) }

  runtime.outbox.singleton_class.remove_method(:deliver)
  redriven = runtime.outbox.redrive!
  after_redrive = { redriven: redriven.map(&:consumer),
                    outbox: runtime.outbox.rows.map(&:status),
                    ledger: !runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Ledger")).find("o-1").nil? }
  policies = runtime.instance_variable_get(:@policies)
  policies.define_singleton_method(:react) { |*| raise Interrupt, "crash after claim" }
  second_crash = nil
  begin
    runtime.dispatch_flat("Shop::Order.Place", number: { value: "o-2" })
  rescue Interrupt => e
    second_crash = e.message
  end
  policies.singleton_class.remove_method(:react)
  after_claimed_crash = { crash: second_crash,
                          stored_order: !order.find("o-2").nil?,
                          outbox: runtime.outbox.rows.map(&:status),
                          redriven_without_evidence: runtime.outbox.redrive!.map(&:consumer),
                          ledger: !runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Ledger")).find("o-2").nil? }
  before_events = runtime.events.length
  before_rows = runtime.outbox.rows.length
  adapter = order.adapter
  adapter.define_singleton_method(:record_event) { |*| raise "disk full" }
  write_failure = nil
  begin
    runtime.dispatch_flat("Shop::Order.Place", number: { value: "o-3" })
  rescue RuntimeError => e
    write_failure = e.message
  end
  adapter.singleton_class.remove_method(:record_event)
  failed_transaction = { error: write_failure, stored_order: !order.find("o-3").nil?,
                         new_events: runtime.events.length - before_events,
                         new_outbox_rows: runtime.outbox.rows.length - before_rows }
  rebooted = Hecks.boot(sandbox)
  rebooted_ledger = rebooted.registry.repository("Shop", rebooted.registry.bluebook("Shop").aggregate("Ledger"))
  after_reboot = { outbox: rebooted.outbox.rows.map(&:status),
                   ledger_o1: !rebooted_ledger.find("o-1").nil?,
                   ledger_o2: !rebooted_ledger.find("o-2").nil? }
  raise "pre-claim commit mismatch" unless after_crash ==
    { crash: "crash before claim", stored_order: true, events: ["OrderPlaced"], outbox: ["pending"] }
  raise "redrive mismatch" unless after_redrive ==
    { redriven: ["policy:Shop::RecordOrder"], outbox: ["delivered"], ledger: true }
  raise "claimed replayed without evidence" unless after_claimed_crash ==
    { crash: "crash after claim", stored_order: true, outbox: ["delivered", "claimed"],
      redriven_without_evidence: [], ledger: false }
  raise "failed transaction was not atomic" unless failed_transaction ==
    { error: "disk full", stored_order: false, new_events: 0, new_outbox_rows: 0 }
  raise "reboot changed claimed delivery" unless after_reboot ==
    { outbox: ["delivered", "claimed"], ledger_o1: true, ledger_o2: false }
  puts JSON.pretty_generate({ after_crash: after_crash, after_redrive: after_redrive,
                              after_claimed_crash: after_claimed_crash,
                              failed_transaction: failed_transaction,
                              after_reboot: after_reboot })
end
