require_relative "ir"
require_relative "../runtime/loader"
require_relative "../runtime/errors"
require_relative "../runtime/value"
require_relative "../runtime/reaction_invocation"
require_relative "../ports/persistence/binding_policy"

# Hecks::Behaviors::Expectations
#
# ## What it does
#
# One test case, start to finish: take the suite's own runtime (booted
# once for exactly what its `loads` names, reset to nothing between
# tests — `runtime_for`), replay `setup` dispatches, dispatch (or query)
# the command under test, check `expect`. Split out of
# runner.rb the same way the file-count/sweep concern is split from a
# single test's own execution.
#
# ## Deviations from a prior port
#
# Two deliberate deviations from a prior port of this same idea (read
# before writing this, not reinvented):
#
# 1. A `setup` refusal and a refusal from the command under test are
#    caught in separate rescue scopes. The prior port wrapped the whole
#    test body — setups included — in one `rescue *REFUSAL_CLASSES`, so a
#    broken setup could spuriously satisfy `expect refused: "..."` if its
#    own refusal happened to match the expected substring. Here, any
#    domain refusal during `setup` is unconditionally an error — the
#    example never got to the situation it claims to test.
#
# 2. `emits:` is read off a `registry.event_log` diff around the tested
#    dispatch, not off `Result#events` alone. `Result#events` only holds
#    the events the outermost dispatch announced; a policy's own cascade
#    reenters through the same `Dispatcher#dispatch` (`PolicyInterpreter
#    #deliver` → `door.reenter` → `dispatch`), and every dispatch's
#    events — outer and reentrant alike — land in the one shared
#    `registry.event_log`, in order (`CommandRules::Emission#emit`,
#    `PortOperationInterpreter#emit`/`#call`). Diffing that log's length
#    before/after the tested dispatch is the one read that actually sees
#    a cascade — this DSL has no `kind: :cascade` because cascades are
#    always on and `emits:` is expected to see them.
module Hecks
  module Behaviors
    # See this file's own header above for what this module does and the
    # two deliberate deviations from the prior port it's built from.
    module Expectations
      module_function

      REFUSAL_CLASSES = Hecks::Runtime::DOMAIN_REFUSALS
      SPECIAL_KEYS = %i[ok refused emits count].freeze

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

        current_setup = nil
        begin
          test.setups.each do |setup|
            current_setup = setup
            dispatch_command(runtime, qualify(setup.command, nil, bluebooks, kind: :command), setup.args)
          end
        rescue *REFUSAL_CLASSES => e
          return error_result(test, "setup #{current_setup&.command.inspect} refused: #{e.message}")
        end

        run_tested(test, runtime, bluebooks)
      rescue StandardError => e
        error_result(test, "#{e.class}: #{e.message}")
      end

      # One boot per suite, not per test. The isolation a test needs is a
      # runtime with nothing in it — and a boot of the same files gives
      # exactly that back for the price of `Registry#reset_runtime_state!`
      # instead of ~2s of loading, verifying and era-checking the same
      # bluebook again (chess: 76 behaviours, 155s of which was booting
      # `chess.bluebook` 76 times). Keyed by the suite's own `loads` and
      # their mtimes, so an edited bluebook boots fresh on the next test
      # rather than running against a stale one — the property a watch
      # loop or a long rspec session actually relies on. `runtime:` lets
      # a caller that already holds a booted runtime (a spec, a REPL)
      # hand it in; it is reset the same way.
      # Not frozen — a real cache, mutated below (`RUNTIMES[key] ||=
      # boot_and_guard(files)`) and by #reset!. False positive for
      # Style/MutableConstant.
      # rubocop:disable-next Style/MutableConstant
      RUNTIMES      = {}
      RUNTIMES_LOCK = Mutex.new
      private_constant :RUNTIMES, :RUNTIMES_LOCK

      # Boots (or reuses the cached boot of) the runtime a suite's `loads` names.
      #
      # @param suite [Behaviors::BehaviorsSuite] the suite whose `loads` files boot
      #   the runtime
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the cached or
      #   freshly booted, Memory-only-guarded runtime
      # @raise [Malformed] if any aggregate the suite boots is not bound to the
      #   default (Memory) adapter
      def runtime_for(suite)
        files = Array(suite.loads).map { |path| File.expand_path(path) }
        key   = files.map { |file| [file, File.exist?(file) ? File.mtime(file).to_f : nil] }

        RUNTIMES_LOCK.synchronize do
          RUNTIMES[key] ||= boot_and_guard(files)
        end
      end

      # `reset_runtime_state!` only drops repository objects between
      # tests (registry.rb) — sufficient isolation for `Memory`, whose
      # `@records` is a plain per-instance ivar, so a fresh object really
      # is a fresh store. Against anything else (Sqlite, Postgres) the
      # rows themselves stay put: tests leak into each other, and a
      # suite booted against a domain's real hecksagon writes to a real
      # database. Refusing that wiring here, at boot, is the same shape
      # of guard `BindingPolicy` already applies to a missing bind — the
      # project's identity is refusing bad wiring up front, not
      # discovering it mid-suite.
      #
      # @param files [Array<String>] absolute paths to the bluebook/hecksagon/world
      #   files to boot
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted,
      #   Memory-only-guarded runtime
      # @raise [Malformed] if any aggregate is bound to a non-Memory adapter
      def boot_and_guard(files)
        runtime = Hecks::Runtime::Loader.boot_files(files, install_facade: false)
        guard_memory_only!(runtime)
        runtime
      end

      # Refuses a runtime where any aggregate is bound to anything other than the
      # default (Memory) adapter, so tests can never leak state or touch a real store.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
      #   runtime to check
      # @return [void]
      # @raise [Malformed] if any aggregate is bound to a non-Memory adapter
      def guard_memory_only!(runtime)
        runtime.registry.bluebooks.each_value do |bluebook|
          bluebook.aggregates.each do |aggregate|
            bind = Ports::Persistence::BindingPolicy.resolve(runtime.registry, bluebook.name, aggregate)
            next if bind.adapter == Ports::Persistence::DEFAULT_ADAPTER

            raise Malformed,
                  "#{bluebook.name}::#{aggregate.hecks_name} is persisted_by " \
                  "#{bind.adapter.inspect}, not #{Ports::Persistence::DEFAULT_ADAPTER.inspect} — " \
                  "a behaviors suite's `loads` must resolve every aggregate to an in-memory " \
                  "binding, or tests leak state into each other and write to a real database. " \
                  "Load a Memory-bound sibling hecksagon instead of the domain's real one — see " \
                  "examples/pizzas/bluebook/pizzas.behaviors's own `loads` comment for the pattern."
          end
        end
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

        if test.expect.key?(:refused)
          return fail_result(test,
                             "expected refused: #{test.expect[:refused].inspect} but dispatch succeeded")
        end

        if (expected_emits = test.expect[:emits])
          actual = runtime.registry.event_log[before..].map(&:name)
          unless actual == expected_emits
            return fail_result(test,
                               "expected emits: #{expected_emits.inspect}, got #{actual.inspect}")
          end
        end

        check_ok(test) || check_fields(test, settled_state(runtime, verb, result)) || pass_result(test)
      end

      # A field expectation reads the aggregate as it stands once the
      # dispatch and its whole cascade have run — the same "cascades are
      # always on" reading `emits:` already commits to. `Result#state` is
      # the wrong source for that: it snapshots the instance the outer
      # dispatch saved, and a policy's own reentrant dispatch (a ply
      # advancing off a Moved event, a move count bumping) hydrates and
      # saves a fresh record afterward — so a field the cascade wrote
      # read back stale (found live: `expect move_count: 1` got 0 while
      # `emits:` saw MoveCountBumped in the same test). The repository
      # holds the settled record; read it back by the id the dispatch
      # itself answered with.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's
      #   booted runtime
      # @param verb [String] the dispatched command's dotted FQN
      # @param result [Runtime::Dispatcher::Result, Runtime::RemoteDispatcher::Result]
      #   the dispatch's own result
      # @return [Hash{Symbol => Object}] the settled record's current state, read
      #   back from the repository; `result.state` (or `{}`) when the result has no
      #   id or the repository no longer has that aggregate/record
      def settled_state(runtime, verb, result)
        return result.state || {} unless result.respond_to?(:id) && result.id

        domain, rest = verb.split("::", 2)
        aggregate_name = rest.to_s.split(".", 2).first
        aggregate = runtime.registry.bluebook(domain)&.aggregate(aggregate_name)
        return result.state || {} unless aggregate

        record = runtime.registry.repository(domain, aggregate).find(result.id)
        record ? record.state : (result.state || {})
      end

      # A behaviors test writes a dispatch the way the guide's own chess
      # examples do — receiver identity and command facts side by side
      # (`label: "g", id: "wn", to: { file: 2, rank: 2 }`) — and since
      # #335 the dispatcher's own `to:` keyword is the routing envelope,
      # so forwarding those kwargs loose collides the moment a domain
      # declares a command fact named `to` (chess does: every Move's own
      # destination). Found live: every such test failed with "to: does
      # not recognize file, rank" while this guide promised the spelling
      # works. `ReactionInvocation.build` is #335's own seam for turning
      # mixed facts into the strict envelope — identities lifted into
      # `to:`, declared facts into `with:` — so a behaviors dispatch now
      # goes through the exact same separation a policy's projection
      # does. A verb that names a port operation (checked explicitly,
      # below — "Pizzas::Order.PaymentGateway.Receive") keeps the loose
      # passthrough instead: its own input already spells the port
      # form's `to:`/`with:`, which the dispatcher's port branch reads
      # directly, and `ReactionInvocation.build`'s explicit envelope
      # expects a command's own declared attributes at the top level,
      # not a port operation's already-wrapped `to:`/`with:` shape.
      #
      # Checks for a port operation directly rather than leaning on
      # `resolve_target` to raise `UnknownVerb` for one — a refusal that held
      # only so long as nothing else ever asked it to resolve a port-operation
      # verb. Now that a `policy` can legitimately `trigger` a port operation
      # (`ReactionInvocation#resolve_target`'s own port-operation branch),
      # that raise no longer happens, so this checks directly instead.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's
      #   booted runtime
      # @param verb [String] the command's dotted FQN, or a port operation's
      # @param args [Hash{Symbol => Object}] the command's (or setup's) facts, mixing
      #   receiver identity and declared arguments
      # @return [Runtime::Dispatcher::Result, Runtime::RemoteDispatcher::Result] the
      #   dispatch's own result
      # @raise [Runtime::UnknownVerb] if `verb` is not fully qualified or names an
      #   undeclared domain, aggregate, command, entity or port operation
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when the
      #   domain refuses the call
      def dispatch_command(runtime, verb, args)
        return runtime.dispatch_flat(verb, args) if port_operation?(runtime, verb)

        invocation = begin
          Runtime::ReactionInvocation.build(registry: runtime.registry, verb: verb,
                                            projected: args, explicit: true)
        rescue Runtime::UnknownVerb
          nil
        end
        return runtime.dispatch_flat(verb, args) unless invocation

        if invocation.key?(:to)
          runtime.dispatch(verb, to: invocation[:to], with: invocation[:with])
        else
          runtime.dispatch(verb, with: invocation[:with])
        end
      end

      # The same "Head.Rest" shape `Dispatcher#dispatch` and
      # `ReactionInvocation#resolve_target` both already check — a bare
      # domain/aggregate lookup plus a port-name lookup, no command
      # resolution needed since all this asks is whether one exists.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's
      #   booted runtime
      # @param verb [String] the verb to check, dotted FQN shaped
      # @return [Boolean] true if `verb` names a port operation on a declared aggregate
      def port_operation?(runtime, verb)
        domain, aggregate_name, command_path = Naming.split_verb(verb)
        return false unless command_path

        aggregate = runtime.registry.bluebook(domain)&.aggregate(aggregate_name)
        return false unless aggregate

        head, rest = command_path.split(".", 2)
        rest && !!aggregate.port(head)
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

        if test.expect.key?(:refused)
          return fail_result(test,
                             "expected refused: #{test.expect[:refused].inspect} but the query succeeded")
        end

        if (expected = test.expect[:count])
          count = if rows.is_a?(Array)
                    rows.size
                  else
                    (rows.nil? ? 0 : 1)
                  end
          return fail_result(test, "expected count: #{expected}, got #{count}") if count != expected
        end

        return check_ok(test) || pass_result(test) unless field_expectations?(test)

        row = query_row(test, rows)
        return row if row.is_a?(Result)

        check_ok(test) || check_fields(test, row) || pass_result(test)
      end

      # Whether `test.expect` names a field, not just one of the special keys.
      #
      # @param test [Behaviors::TestCase] the test case to check
      # @return [Boolean] true if `test.expect` has any key besides `ok`, `refused`,
      #   `emits` or `count`
      def field_expectations?(test)
        test.expect.keys.any? { |key| !SPECIAL_KEYS.include?(key) }
      end

      # A field expectation on a query names one row's shape, so it only
      # makes sense once the query has settled on exactly one — the same
      # reason `expect status: "sold"` on a multi-row answer would be
      # ambiguous about which row it's describing. `check_fields` itself
      # stays row-shaped (it already is, for `run_command`'s settled
      # state); this picks which row it reads.
      #
      # @param test [Behaviors::TestCase] the test case, for the fail message
      # @param rows [Array<Hash>, Hash] the query's own result
      # @return [Hash, Result] `rows` itself when it isn't an Array; its one row when
      #   it holds exactly one; otherwise a `fail_result` naming the row count
      def query_row(test, rows)
        return rows unless rows.is_a?(Array)

        case rows.size
        when 1 then rows.first
        when 0 then fail_result(test, "expect names a field, but the query returned no rows")
        else fail_result(test, "expect names a field, but the query returned #{rows.size} rows — " \
                               "narrow it with `input`/`expect count: 1` first")
        end
      end

      # Checks an `expect ok: true` expectation.
      #
      # @param test [Behaviors::TestCase] the test case to check
      # @return [Result, nil] nil if `test.expect` has no `ok` key or expects `true`;
      #   a `fail_result` if it names anything else
      def check_ok(test)
        return unless test.expect.key?(:ok)

        expected = test.expect[:ok]
        return if expected == true || expected.nil?

        fail_result(test, "expect ok: only accepts true — got #{expected.inspect}")
      end

      # Checks every field-name expectation in `test.expect` against `state`.
      #
      # @param test [Behaviors::TestCase] the test case to check
      # @param state [Hash{Symbol, String => Object}] the settled record's (or query
      #   row's) fields
      # @return [Result, nil] nil if every expected field matches; a `fail_result` for
      #   the first field that names none of `state`'s keys or doesn't match
      def check_fields(test, state)
        test.expect.each do |key, expected|
          next if SPECIAL_KEYS.include?(key)

          unless state.key?(key) || state.key?(key.to_s)
            return fail_result(test, "expect #{key}: names no field on the tested aggregate — " \
                                     "valid expect keys are ok:, refused:, emits:, count: (queries only), " \
                                     "or a real field name")
          end

          actual = normalize(state.key?(key) ? state[key] : state[key.to_s])
          exp    = normalize(expected)
          return fail_result(test, "expected #{key}: #{expected.inspect}, got #{actual.inspect}") unless actual == exp
        end
        nil
      end

      # Checks a caught domain refusal against `test.expect[:refused]`.
      #
      # @param test [Behaviors::TestCase] the test case to check
      # @param error [StandardError] the caught refusal, a member of `REFUSAL_CLASSES`
      # @return [Result] a `pass_result` if `test` expected this refusal's message, an
      #   `error_result` if it expected none, or a `fail_result` if the message doesn't match
      def check_refusal(test, error)
        expected = test.expect[:refused]
        return error_result(test, "unexpected refusal (#{error.class}): #{error.message}") unless expected

        msg = error.message.to_s
        # hecks's given/ensures refusals render "Command refused —
        # <description>" (RefusalWording) ; a behaviors file names just
        # the description — end_with?/include? bridges the prefix.
        return pass_result(test) if msg == expected || msg.end_with?(expected) || msg.include?(expected)

        fail_result(test, "expected refused: #{expected.inspect}, got #{msg.inspect}")
      end

      # The real corpus this DSL is proven against writes VO-typed
      # `expect` values both ways — bare (`expect kind: "bishop"`) and
      # wrapped (`expect kind: { value: "bishop" }`). A live record's
      # field always comes back as a `Hecks::Runtime::Value`;
      # normalizing both sides to the same bare-scalar-or-plain-hash
      # shape is the one comparison that accepts either spelling.
      #
      # @param value [Object] a stored field's value, or an `expect` value to compare
      #   it against
      # @return [Object] the bare underlying value: unwrapped from a `Runtime::Value`,
      #   or from a `{value: ...}` Hash; unchanged otherwise
      def normalize(value)
        return Hecks::Runtime::Value.materialize_unwrapped(value) if value.is_a?(Hecks::Runtime::Value)
        return normalize(value[:value]) if value.is_a?(Hash) && value.keys == [:value]

        value
      end

      # A bare `tests`/`setup` command name carries no domain — `loads`
      # can name more than one bluebook, so resolution searches every
      # aggregate across every bluebook the suite booted for the one that
      # actually declares the command. `on:` (when given, only ever on
      # the tested command — `setup` never receives it, see the DSL
      # contract) narrows the search to one aggregate by name instead of
      # searching all of them.
      #
      # @param command [String, Symbol] a bare verb, or an already-dotted FQN
      # @param on_aggregate [String, Symbol, nil] the aggregate to search, or nil to
      #   search every aggregate of every bluebook
      # @param bluebooks [Array<Bluebook::Chapter>] every chapter the suite booted
      # @param kind [Symbol] `:command` or `:query`
      # @return [String] `command` unchanged if already dotted, otherwise its resolved
      #   dotted FQN
      # @raise [ArgumentError] if no aggregate declares `command`, or more than one does
      def qualify(command, on_aggregate, bluebooks, kind:)
        return command.to_s if command.to_s.include?(".")

        candidates = qualify_candidates(command, on_aggregate, bluebooks, kind)
        disambiguate_qualified_name(candidates, command, kind, bluebooks)
      end

      # Finds every aggregate that could be what a bare command/query name refers to.
      #
      # **The search** — every (bluebook, aggregate) pair that declares a
      # command/query named `command`, narrowed to `on_aggregate` by name
      # when given.
      #
      # @param command [String, Symbol] the bare verb to search for
      # @param on_aggregate [String, Symbol, nil] the aggregate to search, or nil to
      #   search every aggregate of every bluebook
      # @param bluebooks [Array<Bluebook::Chapter>] every chapter the suite booted
      # @param kind [Symbol] `:command` or `:query`
      # @return [Array<Array(Bluebook::Chapter, Bluebook::Aggregate)>] every matching
      #   (chapter, aggregate) pair
      def qualify_candidates(command, on_aggregate, bluebooks, kind)
        members = kind == :query ? :queries : :commands
        pairs =
          if on_aggregate
            bluebooks.filter_map { |bb| (agg = bb.aggregate(on_aggregate)) && [bb, agg] }
          else
            bluebooks.flat_map { |bb| bb.aggregates.map { |agg| [bb, agg] } }
          end
        pairs.select { |_, agg| agg.public_send(members).any? { |m| m.hecks_name == command.to_s } }
      end

      # Resolves a search's candidates to exactly one dotted FQN, or refuses.
      #
      # **The report** — zero candidates and more-than-one candidates both
      # refuse (with a different message); exactly one resolves to its
      # dotted FQN.
      #
      # @param candidates [Array<Array(Bluebook::Chapter, Bluebook::Aggregate)>] the
      #   matching (chapter, aggregate) pairs found by `qualify_candidates`
      # @param command [String, Symbol] the bare verb that was searched for
      # @param kind [Symbol] `:command` or `:query`, for the refusal message
      # @param bluebooks [Array<Bluebook::Chapter>] every chapter the suite booted,
      #   for the refusal message
      # @return [String] the one candidate's dotted FQN
      # @raise [ArgumentError] if `candidates` is empty, or holds more than one
      def disambiguate_qualified_name(candidates, command, kind, bluebooks)
        case candidates.size
        when 0
          raise ArgumentError, "no aggregate among #{bluebooks.map(&:name).inspect} declares a #{kind} " \
                               "named #{command.inspect} — say `on:` if it's ambiguous, or check the spelling"
        when 1
          bluebook, aggregate = candidates.first
          "#{bluebook.name}::#{aggregate.name}.#{command}"
        else
          owners = candidates.map { |bb, agg| "#{bb.name}::#{agg.name}" }
          raise ArgumentError, "#{command.inspect} is declared on more than one aggregate (#{owners.join(', ')}) " \
                               "— say `on:` to disambiguate, or use the dotted FQN"
        end
      end

      # Builds a passing result.
      #
      # @param test [Behaviors::TestCase] the test that passed
      # @return [Result] a `:pass` result
      def pass_result(test) = Result.new(description: test.description, status: :pass, message: nil)

      # Builds a failing result.
      #
      # @param test [Behaviors::TestCase] the test whose expectation was not met
      # @param message [String] what was expected versus what happened
      # @return [Result] a `:fail` result
      def fail_result(test, message)  = Result.new(description: test.description, status: :fail, message: message)

      # Builds an errored result.
      #
      # @param test [Behaviors::TestCase] the test that could not run to a conclusion
      # @param message [String] what went wrong
      # @return [Result] an `:error` result
      def error_result(test, message) = Result.new(description: test.description, status: :error, message: message)

      Result = Struct.new(:description, :status, :message, keyword_init: true)
    end
  end
end
