  # Hecks::DomainInspector
  #
  # Top-level introspection across all loaded domains. Provides summary
  # methods for commands, queries, policies, aggregates, and the glossary.
  # Extended onto the Hecks module so these are available as top-level
  # calls after domains have been loaded.
  #
  # Each method iterates over +domain_objects+ (a Hash of module_name =>
  # Domain maintained by DomainCompiler) to collect information from all
  # loaded domains.
  #
  #   Hecks.commands   # => ["Pizza.CreatePizza(name: String) -> CreatedPizza"]
  #   Hecks.queries    # => ["Pizza.FindByName"]
  #   Hecks.policies   # => ["Pizza: CreatedPizza -> NotifyKitchen"]
  #   Hecks.aggregates # => ["Pizza (name: String, size: String)"]
  #   Hecks.glossary   # prints full glossary to stdout
  #
module Hecks
  module DomainInspector
    # List all commands across all loaded domains. Each entry shows the
    # aggregate, command name, parameters with types, and the resulting event.
    #
    # @return [Array<String>] formatted command signatures like
    #   "Pizza.CreatePizza(name: String) -> CreatedPizza"
    def commands
      each_aggregate.flat_map do |agg|
        agg.commands.each_with_index.map do |cmd, i|
          event = agg.events[i]
          attrs = cmd.attributes.map { |a| "#{a.name}: #{Utils.type_label(a)}" }.join(", ")
          "#{agg.name}.#{cmd.name}(#{attrs}) -> #{event&.name}"
        end
      end
    end

    # List all queries across all loaded domains. Each entry shows the
    # aggregate and query name.
    #
    # @return [Array<String>] formatted query names like "Pizza.FindByName"
    def queries
      each_aggregate.flat_map do |agg|
        agg.queries.map { |q| "#{agg.name}.#{q.name}" }
      end
    end

    # List all reactive policies across all loaded domains, including both
    # aggregate-level and domain-level policies. Shows the event-to-command
    # wiring and whether the policy is async.
    #
    # @return [Array<String>] formatted policy descriptions like
    #   "Pizza: CreatedPizza -> NotifyKitchen [async]"
    def policies
      result = each_aggregate.flat_map do |agg|
        agg.policies.map do |pol|
          async = pol.async ? " [async]" : ""
          "#{agg.name}: #{pol.event_name} -> #{pol.trigger_command}#{async}"
        end
      end

      domain_objects.each_value do |domain|
        domain.policies.each do |pol|
          async = pol.async ? " [async]" : ""
          result << "#{domain.name}: #{pol.event_name} -> #{pol.trigger_command}#{async}"
        end
      end

      result
    end

    # List all aggregates across all loaded domains with their attribute
    # signatures.
    #
    # @return [Array<String>] formatted aggregate summaries like
    #   "Pizza (name: String, size: String)"
    def aggregates
      each_aggregate.map do |agg|
        attrs = agg.attributes.map { |a| "#{a.name}: #{Utils.type_label(a)}" }.join(", ")
        base = "#{agg.name} (#{attrs})"
        agg.description ? "#{base} — #{agg.description}" : base
      end
    end

    # Print the glossary for every loaded domain to stdout.
    #
    # @return [nil]
    def glossary
      domain_objects.each_value { |domain| DomainGlossary.new(domain).print }
      nil
    end

    private

    # Collect all aggregates from all loaded domains into a flat array.
    #
    # @return [Array<Hecks::DomainModel::Aggregate>] all aggregates
    def each_aggregate
      domain_objects.flat_map { |_, domain| domain.aggregates }
    end
  end
end
