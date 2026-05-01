# Hecks::Capabilities::AppBuilder::Planner
#
# Takes a feature description, sends it to Claude, returns a list
# of planned domain additions (aggregates, commands, events, etc.).
#
#   planner = Planner.new(runtime)
#   planner.plan("User Auth", "Login and registration")
#   # => { additions: [{ kind: "aggregate", name: "User", ... }, ...] }
#
require "json"

module Hecks
  module Capabilities
    module AppBuilder
      class Planner
        def initialize(runtime)
          @runtime = runtime
        end

        def plan(title, description)
          adapter = resolve_adapter
          return mock_plan(title, description) unless adapter

          prompt = build_prompt(title, description)
          response = adapter.call(prompt, system_prompt)
          parse_response(response)
        rescue => e
          { error: "Planning failed: #{e.message}", additions: [] }
        end

        private

        def build_prompt(title, description)
          domain_summary = @runtime.domain.aggregates.map { |a|
            cmds = a.commands.map(&:name).join(", ")
            "  #{a.name}: #{cmds}"
          }.join("\n")

          domain = @runtime.domain
          vision = domain.respond_to?(:vision) && domain.vision ? "\nVision: #{domain.vision}\n" : ""

          "Plan the domain additions needed for this feature:\n\n" \
          "Title: #{title}\n" \
          "Description: #{description}\n" \
          "#{vision}\n" \
          "Current domain (#{domain.name}):\n#{domain_summary}\n\n" \
          "Return a JSON array of additions. Each addition has: kind (aggregate/command/event/attribute/policy), " \
          "name, parent (aggregate name for commands/events/attributes), and description.\n\n" \
          "Return ONLY valid JSON, no markdown."
        end

        def system_prompt
          "You are a domain modeling expert. Given a feature description and current domain state, " \
          "plan the exact domain additions needed. Return a JSON array of objects with keys: " \
          "kind, name, parent, description. Kinds: aggregate, command, event, attribute, value_object, policy. " \
          "Be specific and complete. Every command needs an event. Return ONLY the JSON array."
        end

        def resolve_adapter
          return nil unless defined?(Hecks::Extensions::ClaudeCliAdapter)
          world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
          config = world&.config_for(:claude) || {}
          model = config[:model] || "sonnet"

          if config[:api_key] && !config[:api_key].to_s.empty?
            Hecks::Extensions::ClaudeAdapter.new(api_key: config[:api_key], model: model, max_tokens: 4096)
          else
            Hecks::Extensions::ClaudeCliAdapter.new(model: model, max_tokens: 4096)
          end
        rescue
          nil
        end

        def parse_response(response)
          text = response.is_a?(String) ? response : response.to_s
          # Extract JSON array from response
          match = text.match(/\[[\s\S]*\]/)
          return { error: "No JSON in response", additions: [] } unless match
          additions = JSON.parse(match[0])
          { additions: additions.map { |a| a.transform_keys(&:to_s) } }
        rescue JSON::ParserError => e
          { error: "Invalid JSON: #{e.message}", additions: [] }
        end

        def mock_plan(title, description)
          words = title.to_s.split
          agg_name = words.map(&:capitalize).join
          {
            additions: [
              { "kind" => "aggregate", "name" => agg_name, "parent" => nil, "description" => description },
              { "kind" => "command", "name" => "Create#{agg_name}", "parent" => agg_name, "description" => "Create a new #{agg_name.downcase}" },
              { "kind" => "event", "name" => "Created#{agg_name}", "parent" => agg_name, "description" => "#{agg_name} was created" },
              { "kind" => "attribute", "name" => "name", "parent" => agg_name, "description" => "Name of the #{agg_name.downcase}" },
              { "kind" => "attribute", "name" => "status", "parent" => agg_name, "description" => "Current status" }
            ]
          }
        end
      end
    end
  end
end
