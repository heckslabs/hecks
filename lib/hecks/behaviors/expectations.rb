require_relative "ir"
require_relative "../runtime/loader"
require_relative "../runtime/errors"
require_relative "../runtime/value"
require_relative "../runtime/reaction_invocation"
require_relative "../ports/persistence/binding_policy"
require_relative "expectations/boot"
require_relative "expectations/qualify"
require_relative "expectations/checks"
require_relative "expectations/dispatching"

# Runs one behaviors test case: replays its setup dispatches, dispatches (or
# queries) the command under test, and checks the result against `expect`.
module Hecks
  module Behaviors
    # Runs one behaviors test case: replays its setup, dispatches the command, checks `expect`.
    #
    # The runtime boot, name qualification, dispatching and the checks of `expect` live in `Boot`,
    # `Qualify`, `Dispatching` and `Checks`, extended onto this module.
    module Expectations
      REFUSAL_CLASSES = Hecks::Runtime::DOMAIN_REFUSALS
      SPECIAL_KEYS = %i[ok refused emits count].freeze

      # The outcome of one test case.
      Result = Struct.new(:description, :status, :message, keyword_init: true)

      extend Boot
      extend Qualify
      extend Checks
      extend Dispatching

      module_function

      # Runs one test case: replays its `setup` dispatches, dispatches (or queries)
      # the command under test, and checks its `expect`.
      #
      # @param test [Behaviors::TestCase] the test case to run
      # @param suite [Behaviors::BehaviorsSuite] the suite `test` belongs to
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher, nil] an
      #   already-booted runtime to reuse and reset; nil boots (or reuses the cached
      #   boot of) `suite.loads` via `runtime_for`
      # @return [Result] the test's pass, fail, or error outcome
      def run_one(test, suite, runtime: nil)
        runtime ||= runtime_for(suite)
        runtime.registry.reset_runtime_state!
        bluebooks = runtime.registry.bluebooks.values
        replay_setup(test, runtime, bluebooks) || run_tested(test, runtime, bluebooks)
      rescue StandardError => e
        error_result(test, "#{e.class}: #{e.message}")
      end

      # Replays the test's `setup` dispatches.
      #
      # Caught separately from the tested command's own refusal, so a broken setup can't
      # spuriously satisfy `expect refused: "..."` by coincidence.
      #
      # @return [Result, nil] an `error_result` when a setup step is refused; nil otherwise
      def replay_setup(test, runtime, bluebooks)
        current_setup = nil
        test.setups.each do |setup|
          current_setup = setup
          dispatch_command(runtime, qualify(setup.command, nil, bluebooks, kind: :command), setup.args)
        end
        nil
      rescue *REFUSAL_CLASSES => e
        error_result(test, "setup #{current_setup&.command.inspect} refused: #{e.message}")
      end

      # Qualifies and dispatches (or queries) the command under test, catching a
      # domain refusal as the test's own outcome rather than an error.
      #
      # @param test [Behaviors::TestCase] the test case to run
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's
      #   booted runtime
      # @param bluebooks [Array<Bluebook::Chapter>] every chapter the suite booted,
      #   searched to qualify a bare command/query name
      # @return [Result] the test's pass, fail, or error outcome
      def run_tested(test, runtime, bluebooks)
        verb = qualify(test.tests_command, test.on_aggregate, bluebooks, kind: test.kind)

        if test.query?
          run_query(test, runtime, verb)
        else
          run_command(test, runtime, verb)
        end
      rescue *REFUSAL_CLASSES => e
        check_refusal(test, e)
      end

      # Dispatches the command under test and checks its `expect`.
      #
      # @param test [Behaviors::TestCase] the test case to run
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's
      #   booted runtime
      # @param verb [String] the command's dotted FQN
      # @return [Result] the test's pass or fail outcome
      def run_command(test, runtime, verb)
        before = runtime.registry.event_log.length
        result = dispatch_command(runtime, verb, test.input)
        failure = refused_but_succeeded(test, "dispatch") || unexpected_emits(test, runtime, before)
        return failure if failure

        check_ok(test) || check_fields(test, settled_state(runtime, verb, result)) || pass_result(test)
      end

      # Runs the query under test and checks its `expect`.
      #
      # @param test [Behaviors::TestCase] the test case to run
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's
      #   booted runtime
      # @param verb [String] the query's dotted FQN
      # @return [Result] the test's pass or fail outcome
      def run_query(test, runtime, verb)
        rows = runtime.query(verb, **test.input)
        failure = refused_but_succeeded(test, "the query") || unexpected_count(test, rows)
        return failure if failure
        return check_ok(test) || pass_result(test) unless field_expectations?(test)

        check_query_row(test, rows)
      end

      # @return [Result] the outcome of checking the field expectations against the query's one row
      def check_query_row(test, rows)
        row = query_row(test, rows)
        return row if row.is_a?(Result)

        check_ok(test) || check_fields(test, row) || pass_result(test)
      end
    end
  end
end
