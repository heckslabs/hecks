# Hecks::Capabilities::ClientCommands::JsGenerator
#
# Generates a complete browser-side command dispatcher from the
# domain IR. Client-side commands execute locally with state
# management. Server commands go over WebSocket.
#
#   gen = JsGenerator.new(domain, router)
#   gen.generate  # => "// Hecks Client Runtime ..."
#
module Hecks
  module Capabilities
    module ClientCommands
      # Hecks::Capabilities::ClientCommands::JsGenerator
      #
      # Generates JS command dispatcher + client state from domain IR.
      #
      class JsGenerator
        def initialize(domain, router)
          @domain = domain
          @router = router
        end

        def generate
          [header, state_init, dispatch_fn, client_handlers, docs_section, footer].join("\n")
        end

        private

        def header
          <<~JS
            // Hecks Client Runtime — generated from #{@domain.name} Bluebook
            // Do not edit — regenerated on boot from domain IR.
            (function() {
              "use strict";
              var state = {};
              var handlers = {};
          JS
        end

        def state_init
          lines = []
          @domain.aggregates.each do |agg|
            next unless @router.client_side?(agg.name)
            attrs = agg.attributes.map do |a|
              default = a.default || (a.type == String ? '""' : "null")
              default = default.is_a?(String) && !default.start_with?('"') ? "\"#{default}\"" : default
              "    #{a.name}: #{default}"
            end
            lines << "  state.#{agg.name} = {\n#{attrs.join(",\n")}\n  };"
          end
          lines.join("\n")
        end

        def dispatch_fn
          client_aggs = @router.client_aggregates.map { |n| "\"#{n}\"" }.join(", ")
          <<~JS

              var clientAggregates = [#{client_aggs}];

              function dispatch(aggregate, command, args) {
                args = args || {};
                if (clientAggregates.indexOf(aggregate) >= 0) {
                  return dispatchClient(aggregate, command, args);
                } else {
                  return dispatchServer(aggregate, command, args);
                }
              }

              function dispatchClient(aggregate, command, args) {
                var key = aggregate + "." + command;
                var handler = handlers[key];
                if (!handler) {
                  console.warn("No client handler for " + key);
                  return;
                }
                var result = handler(state[aggregate], args);
                if (result && window.HecksApp) {
                  window.HecksApp.handleEvent(result);
                }
                return result;
              }

              function dispatchServer(aggregate, command, args) {
                if (window.HecksIDE && window.HecksIDE.command) {
                  window.HecksIDE.command(aggregate, command, args);
                }
              }
          JS
        end

        def client_handlers
          lines = []
          @domain.aggregates.each do |agg|
            next unless @router.client_side?(agg.name)
            agg.commands.each do |cmd|
              event_name = infer_event_name(cmd)
              lines << generate_handler(agg, cmd, event_name)
            end
          end
          lines.join("\n")
        end

        def generate_handler(agg, cmd, event_name)
          # Generate a state mutation based on command name patterns
          mutation = infer_mutation(agg, cmd)
          <<~JS
              handlers["#{agg.name}.#{cmd.name}"] = function(aggState, args) {
            #{mutation}
                return { event: "#{event_name}", aggregate: "#{agg.name}", data: Object.assign({}, aggState) };
              };
          JS
        end

        def infer_mutation(agg, cmd)
          name = cmd.name
          if name.start_with?("Toggle")
            field = underscore(name.sub("Toggle", ""))
            # Find matching boolean-ish attribute
            attr = agg.attributes.find { |a| underscore(a.name.to_s) == field }
            if attr
              return "    aggState.#{attr.name} = !aggState.#{attr.name};"
            end
          end

          if name.start_with?("Select", "Set")
            # Map command attributes to state
            return cmd.attributes.map { |a|
              "    if (args.#{a.name} !== undefined) aggState.#{a.name} = args.#{a.name};"
            }.join("\n")
          end

          if name.start_with?("Open")
            field = underscore(name.sub("Open", ""))
            attr = agg.attributes.find { |a| underscore(a.name.to_s).include?(field) }
            return "    aggState.#{attr.name} = true;" if attr
          end

          if name.start_with?("Close", "Hide")
            field = underscore(name.sub(/^(Close|Hide)/, ""))
            attr = agg.attributes.find { |a| underscore(a.name.to_s).include?(field) }
            return "    aggState.#{attr.name} = false;" if attr
          end

          # Default: merge args into state
          "    Object.assign(aggState, args);"
        end

        def infer_event_name(cmd)
          return cmd.event_names.first if cmd.respond_to?(:event_names) && cmd.event_names&.any?
          name = cmd.name
          # ToggleSidebar → SidebarToggled, OpenPanel → PanelOpened
          if name =~ /^(Toggle|Open|Close|Select|Hide|Show|Set|Clear|Pause|Resume)(.+)$/
            verb = $1
            noun = $2
            past = { "Toggle" => "Toggled", "Open" => "Opened", "Close" => "Closed",
                     "Select" => "Selected", "Hide" => "Hidden", "Show" => "Shown",
                     "Set" => "Set", "Clear" => "Cleared", "Pause" => "Paused",
                     "Resume" => "Resumed" }
            "#{noun}#{past[verb] || "ed"}"
          else
            "#{name}d"
          end
        end

        def docs_section
          play_cmds = []
          sketch_cmds = []

          @domain.aggregates.each do |agg|
            agg.commands.each do |cmd|
              next if cmd.name =~ /^(Create|Update|Delete|Read)#{agg.name}$/
              attrs = cmd.attributes.map { |a| "#{a.name}:value" }.join(" ")
              line = "#{agg.name}.#{cmd.name}#{attrs.empty? ? "" : " #{attrs}"}"
              desc = cmd.respond_to?(:description) && cmd.description ? cmd.description : ""

              if @router.client_side?(agg.name)
                sketch_cmds << { line: line, desc: desc }
              else
                play_cmds << { line: line, desc: desc }
              end
            end
          end

          play_lines = play_cmds.map { |c| "    { cmd: #{c[:line].inspect}, desc: #{c[:desc].inspect} }" }
          sketch_lines = sketch_cmds.map { |c| "    { cmd: #{c[:line].inspect}, desc: #{c[:desc].inspect} }" }

          <<~JS

              var docs = {
                play: [
            #{play_lines.join(",\n")}
                ],
                sketch: [
            #{sketch_lines.join(",\n")}
                ]
              };
          JS
        end

        def footer
          <<~JS

              window.Hecks = window.Hecks || {};
              window.Hecks.dispatch = dispatch;
              window.Hecks.state = state;
              window.Hecks.handlers = handlers;
              window.Hecks.docs = docs;
            })();
          JS
        end

        def underscore(str)
          str.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
             .gsub(/([a-z\d])([A-Z])/, '\1_\2')
             .downcase
        end
      end
    end
  end
end
