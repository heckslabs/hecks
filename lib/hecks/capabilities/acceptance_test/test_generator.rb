# Hecks::Capabilities::AcceptanceTest::TestGenerator
#
# @domain AcceptanceTest
#
# Generates acceptance test JS from the domain IR. Every command becomes
# a test case that dispatches, checks the right event fired, and verifies
# lifecycle transitions. Uses data-domain tags to assert the DOM matches.
#
#   gen = TestGenerator.new(runtime)
#   gen.generate  # => "// Hecks Acceptance Tests ..."
#
module Hecks
  module Capabilities
    module AcceptanceTest
      class TestGenerator
        def initialize(runtime)
          @domain = runtime.domain
        end

        def generate
          runner = TestRunner.new
          overlay = TestOverlay.new
          [header, test_plan, runner.generate, overlay.generate, ui, footer].join("\n")
        end

        private

        def header
          <<~JS
            // Hecks Acceptance Tests — generated from #{@domain.name}
            (function() {
              "use strict";
              var results = [], running = false;

              function fireEvent(name, data) {
                if (window.HecksApp) window.HecksApp.handleEvent({ event: name, data: data || {} });
              }
          JS
        end

        def test_plan
          tests = []

          @domain.aggregates.each do |agg|
            agg.commands.each do |cmd|
              args = build_args(cmd)
              args_str = args.empty? ? "{}" : "{ #{args.join(", ")} }"
              expected_event = cmd.respond_to?(:emits) ? cmd.emits : nil
              lc_assert = lifecycle_assertion(agg, cmd)

              assert_parts = []
              assert_parts << "expectEvent(#{expected_event.inspect})" if expected_event
              assert_parts << lc_assert if lc_assert

              assert_fn = if assert_parts.any?
                "function() { return #{assert_parts.join(" && ")}; }"
              else
                "null"
              end

              tests << "{ name: #{cmd.name.inspect}, group: #{agg.name.inspect}, " \
                "emits: #{(expected_event || "").inspect}, " \
                "fn: function() { dispatch(#{agg.name.inspect}, #{cmd.name.inspect}, #{args_str}); }, " \
                "assert: #{assert_fn}}"
            end
          end

          "\n  var tests = [\n    #{tests.join(",\n    ")}\n  ];\n"
        end

        def build_args(cmd)
          cmd.attributes.map do |a|
            type = a.type.respond_to?(:name) ? a.type.name.split("::").last : a.type.to_s
            val = (type == "Integer" || type == "Float") ? "1" : '"test"'
            "#{a.name}: #{val}"
          end
        end

        def lifecycle_assertion(agg, cmd)
          return nil unless agg.respond_to?(:lifecycle) && agg.lifecycle
          lc = agg.lifecycle
          lc.transitions.each do |transition_cmd, target|
            next unless transition_cmd == cmd.name
            target_state = target.respond_to?(:target) ? target.target : target.to_s
            return "expectState(#{agg.name.inspect}, #{lc.field.to_s.inspect}, #{target_state.inspect})"
          end
          nil
        end

        def ui
          <<~JS

              function setup() {
                document.addEventListener("click", function(e) {
                  if (e.target.closest("[data-action='run-all-tests']")) runAll();
                  if (e.target.closest("[data-action='reset-tests']")) {
                    results = []; running = false;
                    var c = document.getElementById("test-results");
                    if (c) c.innerHTML = '<p style="color:#666;font-size:13px">Click Run All to test every command.</p>';
                    var o = document.getElementById("hecks-test-overlay");
                    if (o) o.remove();
                  }
                });
              }

              if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", setup);
              else setup();
          JS
        end

        def footer
          "\n  window.HecksTests = { runAll: runAll };\n})();\n"
        end
      end
    end
  end
end
