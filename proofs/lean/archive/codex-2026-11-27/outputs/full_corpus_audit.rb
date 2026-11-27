require "json"
require "hecks"
require "hecks/fuzzing"
require_relative "ir_relationship_core"
require_relative "relationship_reactions"

root = ENV.fetch("HECKS_SOURCE")
fixtures = Dir.glob(File.join(ENV.fetch("FIXTURE_DIR", File.join(root, "spec/corpus/semantics")), "*.json")).sort
results = fixtures.map do |path|
  fixture = JSON.parse(File.read(path))
  name = File.basename(path)
  domain_root = File.join(root, fixture.fetch("domain"))
  begin
    Hecks::Fuzzing::IsolatedBoot.call(domain_root) do |copy|
    runtime = Hecks.boot(copy)
    world = { "instances" => {}, "events" => [], "refusals" => [], "queries" => [], "cross_domain" => [], "sagas" => [] }
    unsupported_output = fixture.fetch("expect").keys - %w[instances events refusals cross_domain sagas]
    raise "unsupported expected output: #{unsupported_output.join(', ')}" unless unsupported_output.empty?
    compiled = {}
    saga_state = {}
    fixture.fetch("steps").each do |step|
      raise "unsupported step shape: #{step.keys.join(', ')}" if step.key?("dry_run") || step.key?("validate")
      if step["query"].is_a?(Hash)
        IRRelationship.run_ad_hoc_query(world, runtime, step.fetch("query"))
        next
      end
      label = step["verb"] || step["query"]
      raise "unsupported ad hoc query" unless label.is_a?(String)
      domain, suffix = label.split("::", 2)
      aggregate_name, member_name = suffix.split(".", 2)
      aggregate = runtime.bluebooks.fetch(domain).aggregate(aggregate_name)
      raise "unknown aggregate #{label}" unless aggregate
      args = step.fetch("args", {})
      if step.key?("query")
        raise "non-Pizza query executor not generalized" unless domain == "Pizzas"
        key = [domain, aggregate_name, "query", member_name]
        program = compiled[key] ||= IRRelationship.compile_query(aggregate, member_name)
        IRRelationship.run_query(program, world, aggregate, member_name, args)
      else
        if member_name.include?(".")
          entity_name, entity_command = member_name.split(".", 2)
          entity = aggregate.entities.find { |candidate| candidate.hecks_name == entity_name }
          raise "unknown entity #{entity_name}" unless entity
          event_start = world.fetch("events").length
          IRRelationship.run_entity(world, aggregate, entity, entity_command, args, domain)
          RelationshipReactions.react(runtime, world, world.fetch("events")[event_start..], 0, compiled, saga_state)
          next
        end
        key = [domain, aggregate_name, "command", member_name]
        program = compiled[key] ||= IRRelationship.compile(aggregate, member_name)
        event_start = world.fetch("events").length
        IRRelationship.run(program, world, aggregate, member_name, args, domain, role: step["role"], runtime: runtime)
        RelationshipReactions.react(runtime, world, world.fetch("events")[event_start..], 0, compiled, saga_state)
      end
    end
    expected = fixture.fetch("expect")
    actual = world.slice(*fixture.fetch("expect").keys)
    if actual == expected
      { fixture: name, status: "match", steps: fixture.fetch("steps").length }
    else
      { fixture: name, status: "mismatch", steps: fixture.fetch("steps").length,
        expected_counts: expected.transform_values { |v| v.respond_to?(:length) ? v.length : nil },
        actual_counts: actual.transform_values { |v| v.respond_to?(:length) ? v.length : nil },
        expected_refusal_kinds: expected.fetch("refusals").map { |r| r.fetch("kind") },
        actual_refusal_kinds: actual.fetch("refusals").map { |r| r.fetch("kind") } }
    end
    end
  rescue StandardError => e
    { fixture: name, status: "unsupported", reason: "#{e.class}: #{e.message.lines.first.to_s.strip}" }
  end
end
summary = results.group_by { |r| r.fetch(:status) }.transform_values(&:length)
puts JSON.pretty_generate({ source_commit: "8a8a2699961a00c54fa6858fa5d7d52bd47d084d",
                            fixture_count: fixtures.length, summary: summary, results: results })
