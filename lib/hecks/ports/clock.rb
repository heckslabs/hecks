require_relative "../runtime/registry"

module Hecks
  module Ports
    # WHAT TIME IT IS — the one fact a domain cannot derive and must not invent.
    #
    # Resolved exactly the way `Ports::IdentityGeneration` resolves its own
    # adapter: one adapter registry-wide implements this, not a per-aggregate
    # binding, because two aggregates in one running app have no real reason to
    # disagree about the time.
    #
    # WHY A PORT AND NOT `Time.now`. A staleness rule — "another agent may take
    # this claim after fifteen minutes" — is untestable against the real clock:
    # a spec for it would either sleep for fifteen minutes or never run at all.
    # Bound to a fixed adapter, the same rule is three lines. That is the whole
    # argument, and it is the same one `SequentialIdentity` makes next door.
    #
    # A PREDICATE STILL CANNOT ASK THE TIME, and this does not change that. The
    # expression sublanguage has no clock and should not: a `given` that read
    # the time would evaluate differently on two runs over the same record, and
    # every replay, audit and fuzz oracle in this repository assumes it does
    # not. So `now` remains an ARGUMENT the predicate merely reads, and this
    # port is what lets a caller stop typing it — the door fills it in, the
    # value is baked into the dispatch, and the recorded step carries the
    # concrete number forever after.
    #
    # WHICH IS WHY THE RUNTIME DOES NOT CALL THIS. `IdentityGeneration`'s own
    # note works through the replay question for a minted uuid and lands on
    # "the value gets baked into the caller's args at the first live dispatch".
    # A clock consulted INSIDE the interpreter would not have that property: a
    # recorded corpus step replayed tomorrow would silently get tomorrow's
    # time, and the fuzzer's oracle and the adapter-agreement gate both compare
    # runs of exactly that shape. So the filling happens at the door, where a
    # human or an agent is typing, and never on the dispatch path a replay uses.
    module Clock
      NAME = "clock"

      module_function

      # SECONDS, AS AN INTEGER, because that is what the sublanguage can do
      # arithmetic on. `claimed_at.value + window.value <= now.value` is
      # addition and comparison — the only two things it has — and a Time
      # object supports neither.
      def now(registry) = adapter(registry).now

      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can say what time it is"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
