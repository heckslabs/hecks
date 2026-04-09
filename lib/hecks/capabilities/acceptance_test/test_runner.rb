# Hecks::Capabilities::AcceptanceTest::TestRunner
#
# @domain AcceptanceTest.RunAll, AcceptanceTest.Reset
#
# Generates the JS test execution loop: dispatch, assert domain state
# changed, assert DOM reflects it, stream results. Uses data-domain
# tags as the contract between the UL and the view.
#
#   runner = TestRunner.new
#   runner.generate  # => JS string
#
module Hecks
  module Capabilities
    module AcceptanceTest
      class TestRunner
        def generate
          [dispatch_fn, assertion_helpers, run_loop, stream_and_finalize].join("\n")
        end

        private

        def dispatch_fn
          <<~JS

              function dispatch(agg, cmd, args) {
                if (window.Hecks && window.Hecks.dispatch) return window.Hecks.dispatch(agg, cmd, args);
                if (window.HecksIDE && window.HecksIDE.command) window.HecksIDE.command(agg, cmd, args);
              }
          JS
        end

        def assertion_helpers
          <<~JS

              function expectEvent(eventName) {
                if (!window.HecksApp) return false;
                var events = window.HecksApp.state.events;
                for (var i = 0; i < Math.min(events.length, 5); i++) {
                  if (events[i].event === eventName) return true;
                }
                return false;
              }

              function expectState(aggName, field, expectedValue) {
                if (window.HecksApp) {
                  var state = window.HecksApp.getState ? window.HecksApp.getState() : window.HecksApp.state;
                  if (state.layout && state.layout[field] !== undefined) {
                    if (String(state.layout[field]) !== String(expectedValue)) return false;
                  }
                }
                var ide = document.getElementById("ide");
                if (ide) {
                  var attrKey = camelCase("domain-" + aggName + "-" + field);
                  if (ide.dataset[attrKey] !== undefined) {
                    return String(ide.dataset[attrKey]) === String(expectedValue);
                  }
                }
                var el = document.querySelector('[data-domain="' + aggName + '.' + field + '"]');
                if (el && el.dataset.domainCollapsed !== undefined) {
                  return String(el.dataset.domainCollapsed) === String(expectedValue);
                }
                return true;
              }

              function camelCase(s) {
                return s.replace(/-([a-z])/g, function(_, c) { return c.toUpperCase(); });
              }
          JS
        end

        def run_loop
          <<~JS

              function runAll() {
                if (running) return;
                running = true; results = [];
                showOverlay(); showProgress(0, tests.length);
                runNext(0);
              }

              var lastGroup = null;

              function runNext(idx) {
                if (idx >= tests.length) { running = false; finalize(); return; }
                var test = tests[idx];
                if (test.group && test.group !== lastGroup) {
                  lastGroup = test.group;
                  appendGroupHeader(test.group);
                }
                showRunning(test.name);
                var before = window.HecksApp ? window.HecksApp.state.events.length : 0;
                var error = null, result = null;
                try { result = test.fn(); } catch(e) { error = e.message; }

                setTimeout(function() {
                  var status = "passed";
                  var reason = "";

                  if (error) {
                    status = "failed"; reason = error;
                  } else if (test.assert) {
                    try {
                      if (!test.assert()) {
                        status = "failed";
                        reason = test.emits ? "expected " + test.emits + " but domain state wrong" : "domain assertion failed";
                      }
                    } catch(e) { status = "failed"; reason = e.message; }
                  } else {
                    var after = window.HecksApp ? window.HecksApp.state.events.length : 0;
                    var clientEvent = result && result.event ? result.event : null;
                    if (!clientEvent && after <= before) { status = "failed"; reason = "no event emitted"; }
                  }

                  var evt = "";
                  if (result && result.event) evt = result.event;
                  else if (window.HecksApp && window.HecksApp.state.events.length > before) {
                    evt = window.HecksApp.state.events[0].event || "";
                  }

                  var r = { command: test.name, group: test.group, event: evt, status: status, reason: reason };
                  results.push(r); appendResult(r); showProgress(idx + 1, tests.length); streamResult(r);
                  setTimeout(function() { runNext(idx + 1); }, 50);
                }, 60);
              }
          JS
        end

        def stream_and_finalize
          <<~JS

              function streamResult(r) {
                if (window.HecksIDE && window.HecksIDE.raw) {
                  window.HecksIDE.raw(JSON.stringify({
                    type: "command", aggregate: "Debug", command: "TestResult",
                    args: { command: r.command, group: r.group || "", event: r.event, status: r.status, reason: r.reason }
                  }));
                }
              }

              function finalize() {
                showRunning(null);
                var passed = results.filter(function(r){return r.status==="passed"}).length;
                var failed = results.length - passed;
                var el = document.getElementById("hecks-test-overlay-title");
                var color = failed > 0 ? "#ef4444" : "#22c55e";
                if (el) { el.textContent = passed + "/" + results.length + " passed"; el.style.color = color; }
                fireEvent("TabSelected", { tab_name: "tests" });
                streamResult({ command: "SUMMARY", status: failed > 0 ? "failed" : "passed", event: passed + "/" + results.length, reason: "" });
              }
          JS
        end
      end
    end
  end
end
