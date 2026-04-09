# Hecks::Capabilities::WebClientState::JsGenerator
#
# Generates the client state management JS. Handles:
# - Optimistic dispatch (local + server)
# - Correlation ID dedup
# - localStorage persistence
# - Restore on load, merge on server connect
#
module Hecks
  module Capabilities
    module WebClientState
      class JsGenerator
        def initialize(runtime)
          @domain = runtime.domain
        end

        def generate
          <<~JS
            // Hecks Client State — generated from #{@domain.name}
            // Optimistic dispatch + localStorage + correlation dedup
            (function() {
              "use strict";

              var STORAGE_KEY = "hecks_state_#{@domain.name.downcase}";
              var pending = {};
              var counter = 0;

              // -- Optimistic Dispatch --
              // 1. Execute locally (instant UI)
              // 2. Send to server with correlation ID (persistence)
              // 3. When echo arrives, skip if already handled

              function optimisticDispatch(aggregate, command, args) {
                args = args || {};
                var correlationId = "c" + (++counter) + "_" + Date.now();

                // Try client-side dispatch first (instant)
                var localResult = null;
                if (window.Hecks && window.Hecks.dispatch) {
                  localResult = window.Hecks.dispatch(aggregate, command, args);
                }

                // If client dispatch didn't produce an event, fire one optimistically
                if (!localResult && window.HecksApp) {
                  var eventName = inferEventName(command);
                  var eventData = Object.assign({}, args);
                  // For toggle commands, infer the toggled state
                  if (command.indexOf("Toggle") === 0) {
                    var field = command.replace("Toggle", "").replace(/([A-Z])/g, "_$1").toLowerCase().substring(1);
                    var st = window.HecksApp.getState();
                    var current = st.layout && st.layout[field + "_collapsed"];
                    eventData[field + "_collapsed"] = !current;
                  }
                  localResult = { event: eventName, aggregate: aggregate, data: eventData };
                  window.HecksApp.handleEvent(localResult);
                }

                // Save to localStorage
                saveState();

                // Send to server with correlation ID
                pending[correlationId] = true;
                if (window.HecksIDE && window.HecksIDE.raw) {
                  window.HecksIDE.raw(JSON.stringify({
                    type: "command",
                    aggregate: aggregate,
                    command: command,
                    args: args,
                    correlation: correlationId
                  }));
                }

                return localResult;
              }

              function inferEventName(command) {
                var match = command.match(/^(Toggle|Open|Close|Select|Hide|Show|Set|Clear|Pause|Resume)(.+)$/);
                if (match) {
                  var verbs = { Toggle:"Toggled", Open:"Opened", Close:"Closed", Select:"Selected",
                    Hide:"Hidden", Show:"Shown", Set:"Set", Clear:"Cleared", Pause:"Paused", Resume:"Resumed" };
                  return match[2] + (verbs[match[1]] || "ed");
                }
                return command + "ed";
              }

              // -- Dedup incoming events --

              function shouldProcess(event) {
                if (!event.correlation) return true;
                if (pending[event.correlation]) {
                  delete pending[event.correlation];
                  return false; // already handled locally
                }
                return true;
              }

              // -- localStorage --

              function saveState() {
                try {
                  if (!window.HecksApp) return;
                  var s = window.HecksApp.state;
                  var toSave = {
                    layout: s.layout,
                    agent: { mode: s.agent.mode },
                    editor: { filename: s.editor.filename }
                  };
                  localStorage.setItem(STORAGE_KEY, JSON.stringify(toSave));
                } catch (e) {}
              }

              function restoreState() {
                try {
                  var saved = localStorage.getItem(STORAGE_KEY);
                  if (!saved) return null;
                  return JSON.parse(saved);
                } catch (e) { return null; }
              }

              // -- Wire into HecksApp --

              function wire() {
                if (!window.HecksApp) {
                  setTimeout(wire, 50);
                  return;
                }

                // Restore from localStorage before server state arrives
                var saved = restoreState();
                if (saved) {
                  var s = window.HecksApp.state;
                  if (saved.layout) Object.assign(s.layout, saved.layout);
                  if (saved.agent) Object.assign(s.agent, saved.agent);
                  if (saved.editor && saved.editor.filename) s.editor.filename = saved.editor.filename;
                }

                // Wrap handleEvent to dedup echoed events
                var origHandler = window.HecksApp.handleEvent;
                window.HecksApp.handleEvent = function(event) {
                  if (!shouldProcess(event)) return;
                  origHandler(event);
                  saveState();
                };
              }

              wire();

              // Replace Hecks.dispatch with optimistic version
              var origDispatch = window.Hecks ? window.Hecks.dispatch : null;
              if (window.Hecks) {
                window.Hecks.optimisticDispatch = optimisticDispatch;
              }

              window.HecksWebClientState = {
                dispatch: optimisticDispatch,
                saveState: saveState,
                restoreState: restoreState
              };
            })();
          JS
        end
      end
    end
  end
end
