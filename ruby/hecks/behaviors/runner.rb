# Hecks::Behaviors::Runner
#
# Runs a TestSuite against a source domain in pure memory. Mirrors
# hecks_life/src/behaviors_runner.rs so the Ruby and Rust runners
# produce identical pass/fail/error counts and per-test results
# (enforced by spec/parity/behaviors_parity_test.rb).
#
# Each test gets a fresh BehaviorRuntime — no state leak. Setups
# dispatch_isolated (don't overshoot precondition state). The test
# command itself dispatches via `dispatch` when `kind: :cascade`,
# otherwise `dispatch_isolated`. Assertions follow the same expect
# map: `refused`, `emits`, `<key>_size`, `count` (queries), and
# plain attribute equality.
#
# Optional `fixtures_file` — when present, the runner seeds every
# fresh runtime with the fixture records before setups/dispatch run,
# so cross-aggregate cascades can read state from sibling aggregates
# without an explicit `setup` chain (i4 gap 8).
#
#   result = Runner.run(source_loader, suite)
#   result = Runner.run(source_loader, suite, fixtures_file: ff)
#   result.passed; result.failed; result.errored
require_relative "behavior_runtime"
require_relative "expectations"
require_relative "fixtures_loader"

module Hecks
  module Behaviors
    class Runner
      TestRun = Struct.new(:description, :status, :message)

      class SuiteResult
        attr_reader :runs
        def initialize(runs); @runs = runs; end
        def passed;  @runs.count { |r| r&.status == :pass  }; end
        def failed;  @runs.count { |r| r&.status == :fail  }; end
        def errored; @runs.count { |r| r&.status == :error || r.nil? }; end
        def all_passed?; failed.zero? && errored.zero?; end
      end

      def self.run(source_loader, suite, fixtures_file: nil)
        runs = suite.tests.map do |t|
          begin
            run_one(source_loader, t, fixtures_file: fixtures_file)
          rescue => e
            TestRun.new(t.description, :error, "runner crash: #{e.message}")
          end
        end
        SuiteResult.new(runs)
      end

      def self.run_one(source_loader, test, fixtures_file: nil)
        domain = source_loader.call
        rt = BehaviorRuntime.boot(domain)
        in_scope = {}
        # Fixture seed BEFORE singleton pre-seed so pre_seed_singletons
        # only fills gaps the fixtures didn't cover (an aggregate with
        # no fixture row still needs its id "1" landing pad).
        in_scope.merge!(FixturesLoader.apply(rt, fixtures_file))
        pre_seed_singletons(rt, in_scope)

        test.setups.each do |setup|
          cmd_name = setup.command
          args     = setup.args || {}
          attrs = build_attrs(args, cmd_name, rt, in_scope)
          begin
            result = rt.dispatch_isolated(cmd_name, attrs)
            in_scope[result.aggregate_type] = result.aggregate_id
          rescue Interpreter::GivenFailed => e
            return TestRun.new(test.description, :error,
              "setup `#{cmd_name}` failed: given failed: #{e.expression}")
          rescue => e
            return TestRun.new(test.description, :error,
              "setup `#{cmd_name}` failed: #{e.message}\n    #{e.backtrace.first(3).join("\n    ")}")
          end
        end

        if test.kind.to_s == "query"
          return Expectations.check_query(test, rt)
        end

        pre_event_count = rt.event_bus.length
        input_attrs = build_attrs(test.input, test.tests_command, rt, in_scope)

        begin
          result = if test.kind.to_s == "cascade"
                     rt.dispatch(test.tests_command, input_attrs)
                   else
                     rt.dispatch_isolated(test.tests_command, input_attrs)
                   end
        rescue Interpreter::GivenFailed => e
          return Expectations.assert_refused(test, expected_refused(test), :given, e)
        rescue => e
          return Expectations.assert_refused(test, expected_refused(test), :error, e) ||
                 TestRun.new(test.description, :error, "dispatch failed: #{e.message}")
        end

        if (expected = expected_refused(test))
          return TestRun.new(test.description, :fail,
            "expected refused: #{expected.inspect}, but command succeeded")
        end

        in_scope[result.aggregate_type] = result.aggregate_id

        # Find state to assert on. Fall back to dispatch landing if the
        # test's named aggregate has no record (mirrors Rust runner).
        assert_agg, assert_id = pick_assert_target(rt, test, in_scope, result)
        state = rt.find(assert_agg, assert_id)
        unless state
          return TestRun.new(test.description, :fail,
            "no in-scope #{test.on_aggregate} after dispatch")
        end

        Expectations.check_state(test, state, rt, pre_event_count)
      end

      # --- private helpers ---
      def self.pre_seed_singletons(rt, in_scope)
        rt.domain.aggregates.each do |agg|
          next unless agg_has_no_bootstrap?(agg)
          # Fixtures seeded this aggregate already — don't overwrite its
          # loaded state with a virgin AggregateState at id "1".
          next if in_scope.key?(agg.name)
          state = AggregateState.new("1")
          rt.repositories[agg.name]["1"] = state
          in_scope[agg.name] = "1"
        end
      end

      def self.agg_has_no_bootstrap?(agg)
        return false if agg.commands.empty?
        agg_snake = to_snake(agg.name)
        agg.commands.all? do |cmd|
          (cmd.references || []).any? do |r|
            t = to_snake(ref_target(r))
            t == agg_snake || agg_snake.end_with?(t)
          end
        end
      end

      # Reference target — Rust IR calls it `target`, Ruby IR `type`.
      def self.ref_target(r)
        (r.respond_to?(:target) ? r.target : r.type).to_s
      end

      def self.ref_name(r)
        r.name.to_s
      end

      def self.build_attrs(args, command_name, rt, in_scope)
        attrs = {}
        (args || {}).each { |k, v| attrs[k.to_s] = v.is_a?(Value) ? v : Value.from(v) }
        _, cmd = rt.find_command(command_name)
        return attrs unless cmd
        (cmd.references || []).each do |r|
          name = ref_name(r)
          next if attrs.key?(name)
          if (id = in_scope[ref_target(r)])
            attrs[name] = Value.from(id)
          end
        end
        attrs
      end

      def self.pick_assert_target(rt, test, in_scope, result)
        in_scope_id = in_scope[test.on_aggregate]
        if in_scope_id && rt.find(test.on_aggregate, in_scope_id)
          [test.on_aggregate, in_scope_id]
        else
          [result.aggregate_type, result.aggregate_id]
        end
      end

      def self.expected_refused(test)
        test.expect[:refused] || test.expect["refused"]
      end

      def self.to_snake(s)
        out = +""
        s.to_s.chars.each_with_index do |c, i|
          out << "_" if c =~ /[A-Z]/ && i > 0
          out << c.downcase
        end
        out
      end
    end
  end
end
