require "json"
require "tmpdir"
require "fileutils"
require "hecks"
require "hecks/runtime/step_run"

source = ENV.fetch("HECKS_SOURCE", "/Users/christopheryoung/Projects/hecks")
Dir.mktmpdir("crystal-hecks-probe-") do |sandbox|
FileUtils.cp_r(File.join(source, "examples/pizzas"), File.join(sandbox, "pizzas"))
runtime = Hecks.boot(File.join(sandbox, "pizzas/bluebook"))
new_pizza = ->(name) do
  { "verb" => "Pizzas::Order.CreatePizza",
    "args" => { "name" => { "value" => name },
                "pizza" => { "price_cents" => { "cents" => 1200 },
                             "size" => { "value" => "large" } } } }
end
steps = [new_pizza.call("First"), new_pizza.call(""), new_pizza.call("Second")]
report = Hecks::StepRun.execute(runtime, steps)
raise "wrong surviving instances" unless report[:instances].keys.sort ==
  ["Pizzas::Order#First", "Pizzas::Order#Second"]
raise "wrong event trace" unless report[:events].map { |event| event[:name] } ==
  ["PizzaCreated", "PizzaCreated"]
raise "wrong refusal count" unless report[:refusals].length == 1
puts JSON.pretty_generate({
  source_commit: "8a8a2699961a00c54fa6858fa5d7d52bd47d084d",
  instance_keys: report[:instances].keys.sort,
  event_names: report[:events].map { |event| event[:name] },
  refusals: report[:refusals]
})
end
