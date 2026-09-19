require_relative "ir"
require_relative "../runtime/loader"
require_relative "../runtime/errors"
require_relative "../runtime/value"
require_relative "../runtime/reaction_invocation"
require_relative "../ports/persistence/binding_policy"

# Hecks::Behaviors::Expectations
#
# One test case, start to finish: take the suite's own runtime (booted
# once for exactly what its `loads` names, reset to nothing between
# tests — `runtime_for`), replay `setup` dispatches, dispatch (or query)
# the command under test, check `expect`. Split out of
# runner.rb the same way the file-count/sweep concern is split from a
# single test's own execution.
module Hecks
  module Behaviors
    # One test case, start to finish: replays a suite's `setup` dispatches, dispatches or
    # queries the command under test, and checks it against `expect`.
    #
    # ## Setup refusals are errors, not the tested refusal
    #
    # A `setup` refusal and a refusal from the command under test are
    # caught in separate rescue scopes, so a broken setup cannot
    # spuriously satisfy `expect refused: "..."` if its
    # own refusal happens to match the expected substring. Any
    # domain refusal during `setup` is unconditionally an error — the
    # example never got to the situation it claims to test.
    #
    # ## `emits:` sees the whole cascade
    #
    # `emits:` is read off a `registry.event_log` diff around the tested
    # dispatch, not off `Result#events` alone. `Result#events` only holds
    # the events the outermost dispatch announced; a policy's own cascade
    # reenters through the same `Dispatcher#dispatch` (`PolicyInterpreter
    # #deliver` → `door.reenter` → `dispatch`), and every dispatch's
    # events — outer and reentrant alike — land in the one shared
    # `registry.event_log`, in order (`CommandRules::Emission#emit`,
    # `PortOperationInterpreter#emit`/`#call`). Diffing that log's length
    # before/after the tested dispatch is the one read that actually sees
    # a cascade — this DSL has no `kind: :cascade` because cascades are
    # always on and `emits:` is expected to see them.
    module Expectations
      module_function

      REFUSAL_CLASSES = Hecks::Runtime::DOMAIN_REFUSALS
      SPECIAL_KEYS = %i[ok refused emits count].freeze

      # Runs one test case end to end: setup dispatches, the tested command or query,
      # then the checks in `expect`.
      #
      # @param test [Behaviors::TestCase] the test to run
      # @param suite [Behaviors::BehaviorsSuite] the suite `test` belongs to, read for
      #   `loads` when no `runtime:` is given
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher, nil] an
      #   already-booted runtime to run against, reset the same way `runtime_for` resets
      #   one; `nil` boots (or reuses the cached boot of) the suite's own `loads`
      # @return [Expectations::Result] `:pass` when every check holds, `:fail` when one
      #   does not, `:error` when a setup refuses or anything else raises
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

      # Boots, or reuses the cached boot of, the suite's own `loads`, keyed by those
      # files' paths and modification times so an edited bluebook boots fresh.
      #
      # @param suite [Behaviors::BehaviorsSuite] the suite whose `loads` to boot
      # @return [Runtime::Dispatcher] the booted, Memory-only runtime
      # @raise [Behaviors::Malformed] if any aggregate the boot loads is bound to
      #   anything other than the default in-memory adapter
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
      # Boots a fresh runtime from the given files and refuses one that persists anything
      # other than in-memory.
      #
      # @param files [Array<String>] absolute paths to boot, as `runtime_for` resolves
      #   the suite's `loads`
      # @return [Runtime::Dispatcher] the booted runtime
      # @raise [Behaviors::Malformed] if any loaded aggregate is bound to anything other
      #   than the default in-memory adapter
      def boot_and_guard(files)
        runtime = Hecks::Runtime::Loader.boot_files(files, install_facade: false)
        guard_memory_only!(runtime)
        runtime
      end

      # Refuses a booted runtime if any aggregate it loaded is bound to anything other
      # than the default in-memory adapter.
      #
      # @param runtime [Runtime::Dispatcher] the just-booted runtime to check
      # @return [void]
      # @raise [Behaviors::Malformed] if an aggregate's bind resolves to any adapter
      #   other than `Ports::Persistence::DEFAULT_ADAPTER`
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

      # Resolves the tested verb's FQN and runs it as a query or a command, turning a
      # domain refusal into the expected `Result` rather than letting it propagate.
      #
      # @param test [Behaviors::TestCase] the test whose `tests_command` to run
      # @param runtime [Runtime::Dispatcher] the suite's booted runtime
      # @param bluebooks [Array<Bluebook::Chapter>] every chapter the runtime loaded, for
      #   `qualify` to search
      # @return [Expectations::Result] `:pass` or `:fail` from the matching runner
      #   (`run_query`/`run_command`), or `:pass`/`:fail` from `check_refusal` when the
      #   verb refuses
      # @raise [ArgumentError] if `qualify` cannot resolve `tests_command` to exactly one
      #   aggregate
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

      # Dispatches the tested command and checks it against `expect refused:`, `emits:`,
      # `ok:` and any field expectations, in that order.
      #
      # @param test [Behaviors::TestCase] the test being run
      # @param runtime [Runtime::Dispatcher] the suite's booted runtime
      # @param verb [String] the command's fully qualified name, as `qualify` resolved it
      # @return [Expectations::Result] `:fail` for the first check that does not hold,
      #   `:pass` when every declared check holds (a command with no `refused:`/`emits:`/
      #   `ok:`/field expectation always passes, since dispatch itself did not raise)
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
      # @param runtime [Runtime::Dispatcher] the suite's booted runtime
      # @param verb [String] the dispatched command's fully qualified name
      # @param result [Runtime::Dispatcher::Result] the tested dispatch's own result
      # @return [Hash{Symbol => Object}] the record's state read back from the
      #   repository by `result.id`, once the whole cascade has settled; `result.state`
      #   (which may itself be `nil`, read here as `{}`) when `result` has no id, the
      #   verb's aggregate cannot be resolved, or the repository holds no such record
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
      # A `policy` can legitimately `trigger` a port operation
      # (`ReactionInvocation#resolve_target`'s own port-operation branch), so
      # `resolve_target` no longer raises `UnknownVerb` for one ; this checks
      # for a port operation directly instead of leaning on a refusal
      # that does not happen.
      # @param runtime [Runtime::Dispatcher] the suite's booted runtime
      # @param verb [String] the fully qualified command or port-operation name
      # @param args [Hash{Symbol => Object}] the test's declared facts, mixing receiver
      #   identity and command facts side by side (`label:`, `id:`, `to:`, declared facts)
      # @return [Runtime::Dispatcher::Result] the dispatch's result
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when the domain
      #   refuses the call
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
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
      # Tells whether a verb names a port operation rather than an ordinary command.
      #
      # @param runtime [Runtime::Dispatcher] the suite's booted runtime, searched for the
      #   named aggregate
      # @param verb [String] the fully qualified verb to check
      # @return [Boolean] true when the verb splits into a domain, aggregate and a
      #   `port_name.operation_name` path naming a declared port; false when the verb is
      #   not qualified, names no aggregate, or its tail is not a port path
      def port_operation?(runtime, verb)
        domain, aggregate_name, command_path = Naming.split_verb(verb)
        return false unless command_path

        aggregate = runtime.registry.bluebook(domain)&.aggregate(aggregate_name)
        return false unless aggregate

        head, rest = command_path.split(".", 2)
        rest && !!aggregate.port(head)
      end

      # Runs the tested query and checks it against `expect refused:`, `count:`, `ok:`
      # and any field expectations, in that order.
      #
      # @param test [Behaviors::TestCase] the test being run
      # @param runtime [Runtime::Dispatcher] the suite's booted runtime
      # @param verb [String] the query's fully qualified name, as `qualify` resolved it
      # @return [Expectations::Result] `:fail` for the first check that does not hold,
      #   `:pass` when every declared check holds
      # @raise [Runtime::NotFound] if a read model's root reference names no record
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared
      #   type
      # @raise [KeyError] if a rooted read model is asked without its reference argument
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
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

      # Tells whether a test's `expect` names at least one field, beyond `ok:`/
      # `refused:`/`emits:`/`count:`.
      #
      # @param test [Behaviors::TestCase] the test to check
      # @return [Boolean] true when `expect` has a key outside `SPECIAL_KEYS`
      def field_expectations?(test)
        test.expect.keys.any? { |key| !SPECIAL_KEYS.include?(key) }
      end

      # A field expectation on a query names one row's shape, so it only
      # makes sense once the query has settled on exactly one — the same
      # reason `expect status: "sold"` on a multi-row answer would be
      # ambiguous about which row it's describing. `check_fields` itself
      # stays row-shaped (it already is, for `run_command`'s settled
      # state); this picks which row it reads.
      # Picks the one row a field expectation checks against, refusing when the query did
      # not settle on exactly one.
      #
      # @param test [Behaviors::TestCase] the test being run, for the refusal message
      # @param rows [Array<Hash>, Hash, nil] the query's own answer: an Array for an
      #   aggregate query, or a single Hash (or `nil`) for a rooted read model
      # @return [Hash, Expectations::Result] `rows` unchanged when it is not an Array
      #   (already one row or none); the one element when the Array holds exactly one;
      #   otherwise a `:fail` `Result` naming zero or several rows
      def query_row(test, rows)
        return rows unless rows.is_a?(Array)

        case rows.size
        when 1 then rows.first
        when 0 then fail_result(test, "expect names a field, but the query returned no rows")
        else fail_result(test, "expect names a field, but the query returned #{rows.size} rows — " \
                               "narrow it with `input`/`expect count: 1` first")
        end
      end

      # Checks a test's `expect ok:` clause, which only ever asserts that the tested verb
      # did not refuse.
      #
      # @param test [Behaviors::TestCase] the test being checked
      # @return [Expectations::Result, nil] `nil` when `expect` has no `ok:` key, or `ok:`
      #   is `true` or `nil`; a `:fail` `Result` when `ok:` is any other value
      def check_ok(test)
        return unless test.expect.key?(:ok)

        expected = test.expect[:ok]
        return if expected == true || expected.nil?

        fail_result(test, "expect ok: only accepts true — got #{expected.inspect}")
      end

      # Checks every non-special `expect` key against the settled state or row, comparing
      # each with `normalize` so a bare or VO-wrapped `expect` value matches either way.
      #
      # @param test [Behaviors::TestCase] the test being checked
      # @param state [Hash] the settled record's state, or the one checked query row;
      #   read by both Symbol and String keys
      # @return [Expectations::Result, nil] a `:fail` `Result` for the first expected key
      #   that names no field, or whose value does not match; `nil` when every field
      #   expectation holds
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

      # Checks a caught domain refusal against `expect refused:`.
      #
      # @param test [Behaviors::TestCase] the test being checked
      # @param error [StandardError] the raised refusal, any class in
      #   `Runtime::DOMAIN_REFUSALS`
      # @return [Expectations::Result] `:error` when `expect` declares no `refused:` at
      #   all (an unexpected refusal); `:pass` when the refusal's message equals, ends
      #   with, or includes the expected text; `:fail` otherwise
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
      # @param value [Object] a live field's value or an `expect`-declared value: a
      #   `Runtime::Value`, a Hash, or any other value
      # @return [Object] a bare `Runtime::Value` unwrapped to its bare scalar; a Hash of
      #   exactly `{value: ...}` normalized the same recursive way; any other value
      #   unchanged
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
      # Resolves a bare `tests`/`setup` command name to its dotted FQN, searching every
      # aggregate across the suite's bluebooks for the one that declares it.
      #
      # @param command [String, Symbol] the command or query name, bare or already dotted
      # @param on_aggregate [String, Symbol, nil] narrows the search to one aggregate by
      #   name; `nil` searches every aggregate in every bluebook
      # @param bluebooks [Array<Bluebook::Chapter>] every chapter the runtime loaded
      # @param kind [Symbol] `:command` or `:query`, which member list to search
      # @return [String] `command` unchanged when it already contains a `.`; otherwise
      #   the resolved `"Domain::Aggregate.command"` FQN
      # @raise [ArgumentError] if no aggregate declares the command, or more than one does
      def qualify(command, on_aggregate, bluebooks, kind:)
        return command.to_s if command.to_s.include?(".")

        candidates = qualify_candidates(command, on_aggregate, bluebooks, kind)
        disambiguate_qualified_name(candidates, command, kind, bluebooks)
      end

      # Finds every (bluebook, aggregate) pair that declares a command or query named
      # `command`, narrowed to `on_aggregate` by name when given.
      #
      # @param command [String, Symbol] the command or query name to search for
      # @param on_aggregate [String, Symbol, nil] narrows the search to one aggregate;
      #   `nil` searches every aggregate in every bluebook
      # @param bluebooks [Array<Bluebook::Chapter>] every chapter the runtime loaded
      # @param kind [Symbol] `:command` or `:query`, which member list to search
      # @return [Array<Array(Bluebook::Chapter, Bluebook::Aggregate)>] every matching
      #   pair; `[]` when none declares the command
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

      # Turns `qualify_candidates`' own result into a resolved FQN, or a refusal naming
      # why it could not resolve one.
      #
      # Zero candidates and more-than-one candidates both
      # refuse (with a different message); exactly one resolves to its
      # dotted FQN.
      #
      # @param candidates [Array<Array(Bluebook::Chapter, Bluebook::Aggregate)>] the
      #   matching pairs `qualify_candidates` found
      # @param command [String, Symbol] the command or query name being resolved
      # @param kind [Symbol] `:command` or `:query`, for the refusal wording
      # @param bluebooks [Array<Bluebook::Chapter>] every chapter the runtime loaded, for
      #   the zero-candidates refusal message
      # @return [String] the resolved `"Domain::Aggregate.command"` FQN, when `candidates`
      #   holds exactly one pair
      # @raise [ArgumentError] if `candidates` is empty, or holds more than one pair
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

      # Builds a passing result for a test.
      #
      # @param test [Behaviors::TestCase] the test that passed
      # @return [Expectations::Result] status `:pass`, with no message
      def pass_result(test) = Result.new(description: test.description, status: :pass, message: nil)

      # Builds a failing result for a test whose checks did not hold.
      #
      # @param test [Behaviors::TestCase] the test that failed
      # @param message [String] what the check expected versus what it found
      # @return [Expectations::Result] status `:fail`, carrying `message`
      def fail_result(test, message)  = Result.new(description: test.description, status: :fail, message: message)

      # Builds an errored result for a test that could not even reach its checks.
      #
      # @param test [Behaviors::TestCase] the test that errored
      # @param message [String] what went wrong: an unexpected setup refusal, or the
      #   raised exception's class and message
      # @return [Expectations::Result] status `:error`, carrying `message`
      def error_result(test, message) = Result.new(description: test.description, status: :error, message: message)

      Result = Struct.new(:description, :status, :message, keyword_init: true)
    end
  end
end
