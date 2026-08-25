require_relative "ir"
require_relative "../runtime/loader"
require_relative "../runtime/errors"
require_relative "../runtime/value"
require_relative "../runtime/reaction_invocation"

# Hecks::Behaviors::Expectations
#
# One test case, start to finish: take the suite's own runtime (booted
# once for exactly what its `loads` names, reset to nothing between
# tests — `runtime_for`), replay `setup` dispatches, dispatch (or query)
# the command under test, check `expect`. Split out of
# runner.rb the same way the file-count/sweep concern is split from a
# single test's own execution.
#
# TWO DELIBERATE DEVIATIONS from a prior port of this same idea (read
# before writing this, not reinvented):
#
# 1. A `setup` refusal and a refusal from the command under test are
#    caught in SEPARATE rescue scopes. The prior port wrapped the whole
#    test body — setups included — in one `rescue *REFUSAL_CLASSES`, so a
#    broken setup could spuriously satisfy `expect refused: "..."` if its
#    own refusal happened to match the expected substring. Here, any
#    domain refusal during `setup` is unconditionally an ERROR — the
#    example never got to the situation it claims to test.
#
# 2. `emits:` is read off a `registry.event_log` DIFF around the tested
#    dispatch, not off `Result#events` alone. `Result#events` only holds
#    the events the OUTERMOST dispatch announced; a policy's own cascade
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
    module Expectations
      module_function

      REFUSAL_CLASSES = Hecks::Runtime::DOMAIN_REFUSALS
      SPECIAL_KEYS = %i[ok refused emits count].freeze

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

      # ONE BOOT PER SUITE, NOT PER TEST. The isolation a test needs is a
      # runtime with nothing in it — and a boot of the same files gives
      # exactly that back for the price of `Registry#reset_runtime_state!`
      # instead of ~2s of loading, verifying and era-checking the same
      # bluebook again (chess: 76 behaviours, 155s of which was booting
      # `chess.bluebook` 76 times). Keyed by the suite's own `loads` AND
      # their mtimes, so an edited bluebook boots fresh on the next test
      # rather than running against a stale one — the property a watch
      # loop or a long rspec session actually relies on. `runtime:` lets
      # a caller that already holds a booted runtime (a spec, a REPL)
      # hand it in; it is reset the same way.
      RUNTIMES      = {}
      RUNTIMES_LOCK = Mutex.new
      private_constant :RUNTIMES, :RUNTIMES_LOCK

      def runtime_for(suite)
        files = Array(suite.loads).map { |path| File.expand_path(path) }
        key   = files.map { |file| [file, File.exist?(file) ? File.mtime(file).to_f : nil] }

        RUNTIMES_LOCK.synchronize do
          RUNTIMES[key] ||= Hecks::Runtime::Loader.boot_files(files, install_facade: false)
        end
      end

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

      def run_command(test, runtime, verb)
        before = runtime.registry.event_log.length
        result = dispatch_command(runtime, verb, test.input)

        return fail_result(test, "expected refused: #{test.expect[:refused].inspect} but dispatch succeeded") if test.expect.key?(:refused)

        if (expected_emits = test.expect[:emits])
          actual = runtime.registry.event_log[before..].map(&:name)
          return fail_result(test, "expected emits: #{expected_emits.inspect}, got #{actual.inspect}") unless actual == expected_emits
        end

        check_ok(test) || check_fields(test, settled_state(runtime, verb, result)) || pass_result(test)
      end

      # A field expectation reads the aggregate AS IT STANDS once the
      # dispatch and its whole cascade have run — the same "cascades are
      # always on" reading `emits:` already commits to. `Result#state` is
      # the wrong source for that: it snapshots the instance the OUTER
      # dispatch saved, and a policy's own reentrant dispatch (a ply
      # advancing off a Moved event, a move count bumping) hydrates and
      # saves a FRESH record afterward — so a field the cascade wrote
      # read back stale (found live: `expect move_count: 1` got 0 while
      # `emits:` saw MoveCountBumped in the same test). The repository
      # holds the settled record; read it back by the id the dispatch
      # itself answered with.
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
      # #335 the dispatcher's own `to:` keyword is the ROUTING envelope,
      # so forwarding those kwargs loose collides the moment a domain
      # declares a command fact named `to` (chess does: every Move's own
      # destination). Found live: every such test failed with "to: does
      # not recognize file, rank" while this guide promised the spelling
      # works. `ReactionInvocation.build` is #335's own seam for turning
      # mixed facts into the strict envelope — identities lifted into
      # `to:`, declared facts into `with:` — so a behaviors dispatch now
      # goes through the exact same separation a policy's projection
      # does. A verb that resolves to no command (a port operation —
      # "Pizzas::Order.PaymentGateway.Receive") keeps the loose
      # passthrough: its own input already spells the port form's
      # `to:`/`with:`, which the dispatcher's port branch reads directly.
      def dispatch_command(runtime, verb, args)
        invocation = begin
          Runtime::ReactionInvocation.build(registry: runtime.registry, verb: verb,
                                            projected: args, explicit: true)
        rescue Runtime::UnknownVerb
          nil
        end
        return runtime.dispatch(verb, **args) unless invocation

        if invocation.key?(:to)
          runtime.dispatch(verb, to: invocation[:to], with: invocation[:with])
        else
          runtime.dispatch(verb, with: invocation[:with])
        end
      end

      def run_query(test, runtime, verb)
        rows = runtime.query(verb, **test.input)

        return fail_result(test, "expected refused: #{test.expect[:refused].inspect} but the query succeeded") if test.expect.key?(:refused)

        if (expected = test.expect[:count])
          count = if rows.is_a?(Array)
                    rows.size
                  else
                    (rows.nil? ? 0 : 1)
                  end
          return fail_result(test, "expected count: #{expected}, got #{count}") if count != expected
        end

        check_ok(test) || pass_result(test)
      end

      def check_ok(test)
        return unless test.expect.key?(:ok)

        expected = test.expect[:ok]
        return if expected == true || expected.nil?

        fail_result(test, "expect ok: only accepts true — got #{expected.inspect}")
      end

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
      # normalizing BOTH sides to the same bare-scalar-or-plain-hash
      # shape is the one comparison that accepts either spelling.
      def normalize(value)
        return Hecks::Runtime::Value.materialize_unwrapped(value) if value.is_a?(Hecks::Runtime::Value)
        return normalize(value[:value]) if value.is_a?(Hash) && value.keys == [:value]

        value
      end

      # A bare `tests`/`setup` command name carries no domain — `loads`
      # can name more than one bluebook, so resolution searches every
      # aggregate across every bluebook the suite booted for the one that
      # actually declares the command. `on:` (when given, only ever on
      # the TESTED command — `setup` never receives it, see the DSL
      # contract) narrows the search to one aggregate by name instead of
      # searching all of them.
      def qualify(command, on_aggregate, bluebooks, kind:)
        return command.to_s if command.to_s.include?(".")

        members = kind == :query ? :queries : :commands
        pairs =
          if on_aggregate
            bluebooks.filter_map { |bb| (agg = bb.aggregate(on_aggregate)) && [bb, agg] }
          else
            bluebooks.flat_map { |bb| bb.aggregates.map { |agg| [bb, agg] } }
          end
        candidates = pairs.select { |_, agg| agg.public_send(members).any? { |m| m.hecks_name == command.to_s } }

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

      def pass_result(test) = Result.new(description: test.description, status: :pass, message: nil)
      def fail_result(test, message)  = Result.new(description: test.description, status: :fail, message: message)
      def error_result(test, message) = Result.new(description: test.description, status: :error, message: message)

      Result = Struct.new(:description, :status, :message, keyword_init: true)
    end
  end
end
