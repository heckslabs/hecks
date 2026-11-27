require "json"
require "tmpdir"
require "fileutils"
require "hecks"

source = ENV.fetch("HECKS_SOURCE", "/Users/christopheryoung/Projects/hecks")
Dir.mktmpdir("crystal-query-") do |sandbox|
  FileUtils.cp_r(File.join(source, "examples/pizzas"), File.join(sandbox, "pizzas"))
  runtime = Hecks.boot(File.join(sandbox, "pizzas/bluebook"))
  runtime.dispatch_flat("Pizzas::Order.CreatePizza",
    name: { value: "First" },
    pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
  before_events = runtime.events.length
  available = runtime.query("Pizzas::Order.Available")
  cheap = runtime.query("Pizzas::Order.CostingLessThan", ceiling: { cents: 1000 })
  after_events = runtime.events.length
  raise "query did not distinguish answers" unless available.length == 1 && cheap.empty?
  raise "query emitted an event" unless before_events == after_events
  puts JSON.pretty_generate({ available_ids: available.map { |row| row[:id] },
                              costing_less_than_1000_ids: cheap.map { |row| row[:id] },
                              event_count_before: before_events,
                              event_count_after: after_events })
end
