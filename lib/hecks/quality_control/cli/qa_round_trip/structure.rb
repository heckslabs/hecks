# frozen_string_literal: true

require "json"

module Hecks
  module QualityControlCli
    class QaRoundTrip
      # Compares two domains by what they declare, read from their IR: aggregates and entities,
      # commands and their arguments, guards by their canonical expression, the fields each command
      # sets and the events it emits, lifecycles, value rules, queries, policies and roles.
      #
      # Each declaration becomes one fact, worded without the names a recovery is free to choose
      # (a value object's own name, a guard's description), so two domains that say the same thing
      # share the fact.
      class Structure
        # The categories a report lists, in its order.
        CATEGORIES = %w[aggregate entity command argument reference given sets emits lifecycle transition
                        value_rule optional query policy role].freeze

        # @param original_ir [Hash] the original domain's IR
        # @param other_ir [Hash] the domain to compare with it
        def initialize(original_ir, other_ir)
          @original = Facts.new(original_ir).to_a
          @other = Facts.new(other_ir).to_a
        end

        # The facts both declare, only the original declares, and only the other declares.
        #
        # @return [Hash{Symbol => Array<Array(String, String)>}] `found:`, `missing:` and
        #   `extra:`, each a list of `[category, fact]` pairs
        def diff
          { found: @original & @other, missing: @original - @other, extra: @other - @original }
        end

        # A table of counts per category, then every missing and extra fact.
        #
        # @return [String] the report
        def report
          parts = diff
          table = CATEGORIES.map { |category| row(category, parts) }
          details = %i[missing extra].flat_map { |part| ["-- #{part}", *parts[part].map { |c, fact| "   #{c}: #{fact}" }] }
          ["category      original  found  missing  extra", *table, *details].join("\n")
        end

        private

        def row(category, parts)
          found, missing, extra = %i[found missing extra].map { |part| parts[part].count { |c, _| c == category } }
          total = @original.count { |c, _| c == category }
          format("%<category>-13s %<total>8d  %<found>5d  %<missing>7d  %<extra>5d",
                 category: category, total: total, found: found, missing: missing, extra: extra)
        end

        # The facts one domain declares, as `[category, fact]` pairs.
        class Facts
          # @param bluebook_ir [Hash] the domain's IR
          def initialize(bluebook_ir)
            @ir = bluebook_ir
          end

          # @return [Array<Array(String, String)>] every fact, each once
          def to_a
            facts = @ir[:aggregates].flat_map { |aggregate| aggregate_facts(aggregate) }
            (facts + @ir[:policies].map do |policy|
              ["policy", "on #{policy[:on_event]} trigger #{policy[:trigger_command]}"]
            end).uniq
          end

          private

          def aggregate_facts(aggregate)
            name = aggregate[:name]
            [["aggregate", "#{name} identified by #{heads(aggregate)}"], *lifecycle_facts(name, aggregate[:lifecycle]),
             *attribute_facts(name, aggregate, aggregate[:attributes]), *query_facts(name, aggregate[:queries]),
             *aggregate[:commands].flat_map { |command| command_facts(name, aggregate, command) },
             *aggregate[:entities].flat_map { |entity| entity_facts(name, aggregate, entity) }]
          end

          def entity_facts(owner, aggregate, entity)
            path = "#{owner}.#{entity[:name]}"
            [["entity", "#{path} identified by #{heads(entity)}"], *attribute_facts(path, aggregate, entity[:attributes]),
             *entity[:commands].flat_map { |command| command_facts(path, aggregate, command) }]
          end

          def command_facts(owner, aggregate, command)
            verb = "#{owner}.#{command[:name]}"
            [["command", verb], *argument_facts(verb, aggregate, command), *command[:givens].map do |g|
              ["given", "#{verb}: #{g[:canonical]}"]
            end,
             *command[:mutations].map { |m| ["sets", "#{verb}: #{m[:target]} #{m[:op]}"] },
             *command[:emits].map do |event|
               ["emits", "#{verb}: #{event}"]
             end, *(command[:role] ? [["role", "#{verb}: #{command[:role]}"]] : [])]
          end

          def argument_facts(verb, aggregate, command)
            command[:attributes].flat_map do |attribute|
              referenced = attribute[:type].to_s[/\AReference<(\w+)>\z/, 1]
              next [["reference", "#{verb} -> #{referenced}"]] if referenced

              [["argument", "#{verb}(#{attribute[:name]}#{", optional" if attribute[:optional]})"],
               *value_rules("#{verb}(#{attribute[:name]})", aggregate, attribute)]
            end
          end

          def attribute_facts(owner, aggregate, attributes)
            attributes.flat_map do |attribute|
              optional = attribute[:optional] ? [["optional", "#{owner}.#{attribute[:name]}"]] : []
              optional + value_rules("#{owner}.#{attribute[:name]}", aggregate, attribute)
            end
          end

          # A value object's closed set and invariants, keyed by the field that holds it rather
          # than by the value object's own name.
          def value_rules(field, aggregate, attribute)
            shape = aggregate[:value_objects].find { |value_object| value_object[:name] == attribute[:type].to_s }
            return [] unless shape

            invariants = shape[:invariants].map { |invariant| ["value_rule", "#{field}: #{invariant[:canonical]}"] }
            closed_set_rule(field, shape) + invariants
          end

          def closed_set_rule(field, shape)
            return [] unless shape[:closed_set]

            [["value_rule", "#{field} one of #{shape[:members].flatten(1).map(&:last).sort.inspect}"]]
          end

          def lifecycle_facts(owner, lifecycle)
            return [] unless lifecycle

            [["lifecycle", "#{owner}.#{lifecycle[:field]} starts #{lifecycle[:default]}"],
             *lifecycle[:transitions].map { |t| ["transition", "#{owner}: #{t[:command]} #{t[:from_state]} -> #{t[:to_state]}"] }]
          end

          def query_facts(owner, queries)
            queries.map do |query|
              ["query",
               "#{owner}.#{query[:name]} where #{JSON.generate(query[:wheres])} order #{JSON.generate(query[:order_by])}"]
            end
          end

          def heads(construct) = construct[:identified_by].map { |path| path.split(".").first }.join(", ")
        end
      end
    end
  end
end
