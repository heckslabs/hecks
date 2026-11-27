require_relative "../outputs/ir_relationship_core"
root = ENV.fetch("HECKS_SOURCE")
runtime = Hecks.boot(File.join(root, "examples/pizzas/bluebook"))
aggregate = runtime.bluebooks.fetch("Pizzas").aggregate("Order")
commands = %w[CreatePizza AddTopping Purchase]
compiled = commands.to_h { |name| [name, IRRelationship.compile(aggregate, name)] }
query_name = "CostingLessThan"
query_program = IRRelationship.compile_query(aggregate, query_name)
File.write(ENV.fetch("PROGRAM_DUMP"), JSON.pretty_generate(compiled.merge(query_name => query_program))) if ENV["PROGRAM_DUMP"]
names = %w[accepted_pizza_lifecycle given_unmet_leaves_the_record_purchasable
           collection_guard_toppings absent_argument_refused vo_pattern_before_invariant
           string_field_refuses_other_scalars vo_field_null_refused query_argument_typed]
results = names.map do |name|
  fixture = JSON.parse(File.read(File.join(root, "spec/corpus/semantics/#{name}.json")))
  world = { "instances" => {}, "events" => [], "refusals" => [], "queries" => [] }
  fixture.fetch("steps").each do |step|
    if step["query"]
      query = step.fetch("query").split(".").last
      IRRelationship.run_query(query_program, world, aggregate, query, step.fetch("args", {}))
    else
      command = step.fetch("verb").split(".").last
      IRRelationship.run(compiled.fetch(command), world, aggregate, command, step.fetch("args"))
    end
  end
  match = world.slice("instances", "events", "refusals") == fixture.fetch("expect")
  query_match = nil
  if name == "query_argument_typed"
    require "hecks/fuzzing"
    reference = Hecks::Fuzzing::Replay.call(File.join(root, fixture.fetch("domain")), fixture.fetch("steps"))
    expected_queries = reference.fetch(:queries).map do |q|
      entry = { "rows" => q[:rows] && IRRelationship.copy(q[:rows]) }
      entry["error"] = q[:error] if q[:error]
      entry
    end
    query_match = world.fetch("queries") == expected_queries
    match &&= query_match
  end
  { fixture: name, matched: match,
    query_answer_matched: query_match,
    query_observations: (world.fetch("queries") if name == "query_argument_typed"),
    actual_refusals: (world.fetch("refusals") unless match),
    expected_refusals: (fixture.fetch("expect").fetch("refusals") unless match) }.compact
end
synthetic_steps = [
  { "verb" => "Pizzas::Order.CreatePizza", "args" => {
    "name" => { "value" => "zeta" },
    "pizza" => { "price_cents" => { "cents" => 1200 }, "size" => { "value" => "large" } }
  } },
  { "verb" => "Pizzas::Order.CreatePizza", "args" => {
    "name" => { "value" => "alpha" },
    "pizza" => { "price_cents" => { "cents" => 800 }, "size" => { "value" => "small" } }
  } },
  { "query" => "Pizzas::Order.CostingLessThan", "args" => { "ceiling" => { "cents" => 1000 } } },
  { "query" => "Pizzas::Order.CostingLessThan", "args" => { "ceiling" => { "cents" => 2000 } } }
]
synthetic_world = { "instances" => {}, "events" => [], "refusals" => [], "queries" => [] }
synthetic_steps.each do |step|
  if step["query"]
    IRRelationship.run_query(query_program, synthetic_world, aggregate, query_name, step.fetch("args"))
  else
    IRRelationship.run(compiled.fetch("CreatePizza"), synthetic_world, aggregate,
                       "CreatePizza", step.fetch("args"))
  end
end
require "hecks/fuzzing"
synthetic_reference = Hecks::Fuzzing::Replay.call(File.join(root, "examples/pizzas"), synthetic_steps)
synthetic_match = synthetic_world.fetch("queries") == synthetic_reference.fetch(:queries).map do |q|
  { "rows" => IRRelationship.copy(q.fetch(:rows)) }
end
lifecycle_checks = %w[Purchase AddTopping].to_h do |attempt|
  base = JSON.parse(File.read(File.join(root, "spec/corpus/semantics/accepted_pizza_lifecycle.json")))
  steps = base.fetch("steps") + [attempt == "Purchase" ? base.fetch("steps")[2] : base.fetch("steps")[1]]
  world = { "instances" => {}, "events" => [], "refusals" => [] }
  steps.each do |step|
    command = step.fetch("verb").split(".").last
    IRRelationship.run(compiled.fetch(command), world, aggregate, command, step.fetch("args"))
  end
  reference = Hecks::Fuzzing::Replay.call(File.join(root, "examples/pizzas"), steps)
  expected = {
    "instances" => IRRelationship.copy(reference.fetch(:instances)),
    "events" => IRRelationship.copy(reference.fetch(:events)),
    "refusals" => IRRelationship.copy(reference.fetch(:refusals)).map do |row|
      row["kind"] = row.fetch("kind").split("::").last
      row
    end
  }
  [attempt, world == expected]
end
meter_root = File.join(root, "spec/corpus/semantics/domains/meter")
meter_runtime = Hecks.boot(File.join(meter_root, "bluebook"))
meter_aggregate = meter_runtime.bluebooks.fetch("Metering").aggregate("Gauge")
meter_programs = %w[Install Read].to_h do |name|
  [name, IRRelationship.compile(meter_aggregate, name)]
end
meter_fixture = JSON.parse(File.read(File.join(root, "spec/corpus/semantics/effects_read_the_pre_state.json")))
meter_worlds = [:pre, :candidate].to_h do |source_mode|
  world = { "instances" => {}, "events" => [], "refusals" => [] }
  meter_fixture.fetch("steps").each do |step|
    command = step.fetch("verb").split(".").last
    IRRelationship.run(meter_programs.fetch(command), world, meter_aggregate, command,
                       step.fetch("args"), "Metering", state_sources: source_mode)
  end
  [source_mode, world]
end
meter_match = meter_worlds.fetch(:pre) == meter_fixture.fetch("expect")
naive_meter_match = meter_worlds.fetch(:candidate) == meter_fixture.fetch("expect")
meter_state = meter_worlds.fetch(:pre).fetch("instances").fetch("Metering::Gauge#m1")
naive_meter_state = meter_worlds.fetch(:candidate).fetch("instances").fetch("Metering::Gauge#m1")
File.write(ENV.fetch("METER_PROGRAM_DUMP"), JSON.pretty_generate(meter_programs)) if ENV["METER_PROGRAM_DUMP"]
puts JSON.pretty_generate({ compiled_tags: (compiled.values.flatten(1) + query_program).map(&:first).uniq.sort,
                            compiled_instruction_counts: compiled.transform_values(&:length).merge(query_name => query_program.length),
                            results: results,
                            sold_state_refusal_matches: lifecycle_checks,
                            meter_second_domain: {
                              matched: meter_match,
                              compiled_instruction_counts: meter_programs.transform_values(&:length),
                              current: meter_state.fetch("current"), previous: meter_state.fetch("previous"),
                              sequential_candidate_read_matched: naive_meter_match,
                              sequential_candidate_previous: naive_meter_state.fetch("previous")
                            },
                            two_pizza_query_match: synthetic_match,
                            two_pizza_query_ids: synthetic_world.fetch("queries").map do |q|
                              q.fetch("rows").map { |row| row.fetch("id") }
                            end })
exit(results.all? { |r| r.fetch(:matched) } && synthetic_match && lifecycle_checks.values.all? &&
     meter_match && !naive_meter_match ? 0 : 1)
