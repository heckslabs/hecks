# Hecks::Capabilities::Workbench::ReplGenerator
#
# Generates the workbench REPL JavaScript from the domain IR.
# The generated JS knows every aggregate, command, and attribute
# so it can provide autocomplete, help, and dispatch.
#
#   gen = ReplGenerator.new(runtime)
#   gen.generate  # => "// Hecks Workbench ..."
#
module Hecks
  module Capabilities
    module Workbench
      # Hecks::Capabilities::Workbench::ReplGenerator
      #
      # Generates domain-aware REPL JS from the runtime's domain IR.
      #
      class ReplGenerator
        def initialize(runtime, annotations: [])
          @domain = runtime.domain
          @annotations = annotations
          @workbench_aggregates = annotations.map { |a| a[:aggregate].to_s.split("::").last }
        end

        def generate
          [header, domain_data, repl_core, commands_section, footer].join("\n")
        end

        private

        def header
          <<~JS
            // Hecks Workbench — generated from #{@domain.name} Bluebook
            // Live REPL for executing commands and inspecting state.
            (function() {
              "use strict";
          JS
        end

        def domain_data
          aggs = @domain.aggregates.map do |agg|
            cmds = agg.commands.map do |cmd|
              attrs = cmd.attributes.map do |a|
                type = a.type.respond_to?(:name) ? a.type.name.split("::").last : a.type.to_s
                "{ name: #{a.name.to_s.inspect}, type: #{type.inspect} }"
              end
              "{ name: #{cmd.name.inspect}, attrs: [#{attrs.join(", ")}] }"
            end
            "{ name: #{agg.name.inspect}, commands: [#{cmds.join(", ")}] }"
          end

          <<~JS
              var domain = {
                name: #{@domain.name.inspect},
                aggregates: [
                  #{aggs.join(",\n        ")}
                ]
              };
          JS
        end

        def repl_core
          <<~JS

              function init() {
                var output = document.getElementById("workbench-output");
                var input = document.getElementById("workbench-input");
                if (!output || !input) return;

                showWelcome(output);

                var history = [];
                var historyIndex = -1;

                input.addEventListener("keydown", function(e) {
                  if (e.key === "Enter" && !e.shiftKey) {
                    e.preventDefault();
                    var line = input.value.trim();
                    if (!line) return;
                    history.unshift(line);
                    historyIndex = -1;
                    input.value = "";
                    execute(output, line);
                  } else if (e.key === "ArrowUp") {
                    e.preventDefault();
                    if (historyIndex < history.length - 1) { historyIndex++; input.value = history[historyIndex]; }
                  } else if (e.key === "ArrowDown") {
                    e.preventDefault();
                    if (historyIndex > 0) { historyIndex--; input.value = history[historyIndex]; }
                    else { historyIndex = -1; input.value = ""; }
                  } else if (e.key === "Tab") {
                    e.preventDefault();
                    var partial = input.value.trim();
                    var match = autocomplete(partial);
                    if (match) input.value = match;
                  }
                });
              }

              function execute(out, line) {
                appendLine(out, "input", "> " + line);

                if (line === "help") { showHelp(out); return; }
                if (line === "clear") { out.innerHTML = ""; return; }
                if (line === "list") { showAggregates(out); return; }
                if (line === "events") { queryServer("events", {}); return; }
                if (line.match(/^inspect\\s+(\\w+)/)) {
                  queryServer("inspect", { aggregate: line.match(/^inspect\\s+(\\w+)/)[1] });
                  return;
                }
                if (line.match(/^find\\s+(\\w+)\\s+(\\S+)/)) {
                  var m = line.match(/^find\\s+(\\w+)\\s+(\\S+)/);
                  queryServer("find", { aggregate: m[1], id: m[2] });
                  return;
                }

                // Command dispatch: Aggregate.Command key:val
                var dotMatch = line.match(/^(\\w+)\\.(\\w+)\\s*(.*)$/);
                if (dotMatch) {
                  dispatch(out, dotMatch[1], dotMatch[2], parseArgs(dotMatch[3] || ""));
                  return;
                }

                // Bare command: CommandName key:val
                var cmdMatch = line.match(/^(\\w+)\\s*(.*)$/);
                if (cmdMatch) {
                  var agg = findAggregate(cmdMatch[1]);
                  if (agg) { dispatch(out, agg, cmdMatch[1], parseArgs(cmdMatch[2] || "")); return; }
                  appendLine(out, "warn", "Unknown: " + cmdMatch[1] + ". Type 'list' for commands.");
                  return;
                }

                appendLine(out, "warn", "Could not parse. Type 'help' for syntax.");
              }
          JS
        end

        def commands_section
          <<~JS

              function dispatch(out, aggregate, command, args) {
                appendLine(out, "exec", ">>> " + aggregate + "." + command + "(" + JSON.stringify(args) + ")");
                if (window.HecksIDE && window.HecksIDE.command) {
                  window.HecksIDE.command(aggregate, command, args);
                } else if (window.Hecks && window.Hecks.dispatch) {
                  var result = window.Hecks.dispatch(aggregate, command, args);
                  if (result && result.event) {
                    appendLine(out, "event", "<<< " + result.event + " " + JSON.stringify(result.data || {}));
                  }
                  return;
                }
                // Wait for server event
                setTimeout(function() {
                  var events = window.HecksApp && window.HecksApp.state && window.HecksApp.state.events;
                  if (events && events.length > 0) {
                    var last = events[0];
                    appendLine(out, "event", "<<< " + (last.event || "?") + " " + JSON.stringify(last.data || {}));
                  }
                }, 500);
              }

              function queryServer(action, params) {
                if (window.HecksIDE && window.HecksIDE.raw) {
                  window.HecksIDE.raw(JSON.stringify({ type: "workbench", action: action, aggregate: params.aggregate, id: params.id }));
                }
              }

              function parseArgs(str) {
                var args = {};
                if (!str) return args;
                var pairs = str.match(/(\\w+):("[^"]*"|\\S+)/g);
                if (pairs) pairs.forEach(function(p) {
                  var kv = p.split(":");
                  args[kv[0]] = kv.slice(1).join(":").replace(/^"|"$/g, "");
                });
                return args;
              }

              function findAggregate(cmdName) {
                for (var i = 0; i < domain.aggregates.length; i++) {
                  var agg = domain.aggregates[i];
                  for (var j = 0; j < agg.commands.length; j++) {
                    if (agg.commands[j].name === cmdName) return agg.name;
                  }
                }
                return null;
              }

              function autocomplete(partial) {
                var all = [];
                domain.aggregates.forEach(function(a) {
                  all.push(a.name);
                  a.commands.forEach(function(c) {
                    all.push(a.name + "." + c.name);
                    all.push(c.name);
                  });
                });
                all.push("help", "clear", "list", "events", "inspect", "find");
                var matches = all.filter(function(s) { return s.toLowerCase().indexOf(partial.toLowerCase()) === 0; });
                return matches.length === 1 ? matches[0] : null;
              }

              function showWelcome(out) {
                appendLine(out, "system", "Hecks Workbench — " + domain.name);
                appendLine(out, "hint", "Type 'help' for commands, 'list' for aggregates, Tab to autocomplete.");
                appendLine(out, "hint", "");
              }

              function showHelp(out) {
                appendLine(out, "info", "Commands:");
                appendLine(out, "hint", "  Aggregate.Command key:val  — dispatch a command");
                appendLine(out, "hint", "  CommandName key:val         — auto-find aggregate");
                appendLine(out, "hint", "  inspect Aggregate          — list all records");
                appendLine(out, "hint", "  find Aggregate id          — find one record");
                appendLine(out, "hint", "  events                     — show event history");
                appendLine(out, "hint", "  list                       — show all aggregates");
                appendLine(out, "hint", "  clear                      — clear output");
              }

              function showAggregates(out) {
                domain.aggregates.forEach(function(a) {
                  var cmds = a.commands.map(function(c) {
                    var args = c.attrs.map(function(at) { return at.name + ":" + at.type; }).join(" ");
                    return c.name + (args ? " " + args : "");
                  });
                  appendLine(out, "info", a.name);
                  cmds.forEach(function(c) { appendLine(out, "hint", "  " + c); });
                });
              }

              var STYLES = {
                input: "color:#888", info: "color:#aaa", exec: "color:#4361ee",
                event: "color:#22c55e", warn: "color:#ef4444",
                hint: "color:#666;font-style:italic", system: "color:#555;font-style:italic"
              };

              function appendLine(out, kind, text) {
                var style = STYLES[kind] || "color:#aaa";
                var el = document.createElement("div");
                el.style.cssText = style + ";white-space:pre-wrap;font-family:monospace;font-size:13px;line-height:1.6";
                el.textContent = text;
                out.appendChild(el);
                out.scrollTop = out.scrollHeight;
              }
          JS
        end

        def footer
          <<~JS

              // Listen for workbench query results
              if (window.HecksApp) {
                var origHandler = window.HecksApp.handleEvent;
                window.HecksApp.handleEvent = function(event) {
                  if (event.type === "workbench_result" && event.data) {
                    var out = document.getElementById("workbench-output");
                    if (out) appendLine(out, "event", JSON.stringify(event.data, null, 2));
                  }
                  if (origHandler) origHandler(event);
                };
              }

              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", init);
              } else {
                setTimeout(init, 100);
              }

              window.HecksWorkbench = { domain: domain, execute: execute };
            })();
          JS
        end
      end
    end
  end
end
