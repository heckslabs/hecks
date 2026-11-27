require_relative "ir"
require_relative "../runtime/loader"
require_relative "../runtime/caller"
require_relative "../runtime/errors"
require_relative "../runtime/value"
require_relative "../runtime/reaction_invocation"
require_relative "../runtime/kernel_dispatcher"
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
      # What refuses the tested step: a domain refusal, or the kernel's refusal of a dispatch,
      # which names no class yet and is matched by its text.
      TESTED_REFUSALS = (REFUSAL_CLASSES + [Hecks::Runtime::KernelDispatcher::Refused]).freeze
      SPECIAL_KEYS = %i[ok refused emits count].freeze

      # The outcome of one test case. `adapter` names the stand-ins its variant picked, when the
      # suite runs once per adapter; nil otherwise.
      Result = Struct.new(:description, :status, :message, :adapter, keyword_init: true)

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
      # @param runtime [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher,
      #   Runtime::KernelDispatcher, nil] an already-booted runtime to reuse and reset; nil boots
      #   (or reuses the cached boot of) `suite.loads` via `runtime_for`, on `HECKS_ENGINE`
      # @param adapters [Array<String>, nil] the `.adapter` files of the variant to boot; nil
      #   lets `AdapterSelection` choose
      # @return [Result] the test's pass, fail, or error outcome
      def run_one(test, suite, runtime: nil, adapters: nil)
        runtime ||= runtime_for(suite, adapters: adapters)
        reset(runtime)
        registry = runtime.registry
        bluebooks = registry.bluebooks.values
        replay_setup(test, runtime, bluebooks) || run_tested(test, runtime, bluebooks)
      rescue StandardError => e
        error_result(test, "#{e.class}: #{e.message}")
      end

      # Clears what the previous test left: the kernel's store goes back to its snapshot, the
      # in-process runtime's Memory stores and event log are emptied.
      #
      # @param runtime [Object] the suite's booted runtime
      # @return [void]
      def reset(runtime)
        return runtime.reset! if runtime.is_a?(Hecks::Runtime::KernelDispatcher)

        runtime.registry.reset_runtime_state!
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
          verb = qualify(setup.command, nil, bluebooks, kind: :command)
          as_role(setup.role) { dispatch_command(runtime, verb, setup.args) }
        end
        nil
      rescue *TESTED_REFUSALS => e
        error_result(test, "setup #{current_setup&.command.inspect} refused: #{e.message}")
      end

      # Runs the block as a caller holding `role`, or with no caller bound when there is none.
      #
      # @param role [String, nil] the role the dispatch runs as
      # @yield the dispatch
      # @return [Object] the block's result
      def as_role(role, &)
        return yield unless role

        Hecks::Runtime::Caller.as(role: role, &)
      end

      # Qualifies and dispatches (or queries) the command under test, catching a
      # domain refusal as the test's own outcome rather than an error.
      #
      # @param test [Behaviors::TestCase] the test case to run
      # @param runtime [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the suite's
      #   booted runtime
      # @param bluebooks [Array<Bluebook::Declaration>] every bluebook the suite booted,
      #   searched to qualify a bare command/query name
      # @return [Result] the test's pass, fail, or error outcome
      def run_tested(test, runtime, bluebooks)
        verb = qualify(test.tests_command, test.on_aggregate, bluebooks, kind: test.kind)

        if test.query?
          run_query(test, runtime, verb)
        else
          run_command(test, runtime, verb)
        end
      rescue *TESTED_REFUSALS => e
        check_refusal(test, e)
      end

      # Dispatches the command under test and checks its `expect`.
      #
      # @param test [Behaviors::TestCase] the test case to run
      # @param runtime [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the suite's
      #   booted runtime
      # @param verb [String] the command's dotted FQN
      # @return [Result] the test's pass or fail outcome
      def run_command(test, runtime, verb)
        before = runtime.events.length
        result = as_role(test.role) { dispatch_command(runtime, verb, test.input) }
        failure = refused_but_succeeded(test, "dispatch") || unexpected_emits(test, runtime, before)
        return failure if failure

        check_ok(test) || check_fields(test, settled_state(runtime, verb, result)) || pass_result(test)
      end

      # Runs the query under test and checks its `expect`.
      #
      # @param test [Behaviors::TestCase] the test case to run
      # @param runtime [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the suite's
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
