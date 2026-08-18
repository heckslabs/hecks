require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class DomainPortBuilder
        GRAMMAR_CONTEXT = "DomainPort"

        include WordGate

        def initialize(name, owner: nil)
          @name       = name
          @owner      = owner
          @operations = []
        end

        # WHAT THE OUTSIDE TELLS US — an external fact arriving, translated
        # into this domain's own word for it. Spelled `operation` before it
        # had a twin, and `operation` still works: the corpus is full of it,
        # and renaming a word costs every chapter that uses it for no gain a
        # reader can feel.
        #
        # RENAMED FROM `tells` — item #13's full metaprogrammed dispatch
        # (slice 4c). `operation`/`tells` are TWO separate Keyword rows
        # (a word admitting two forms) that both name `calls: "tells_impl"`
        # — the routing between the two spellings now lives in the table,
        # not in a Ruby `alias`. Not bootstrap-reachable (checked
        # directly), so no BOOTSTRAP_CALLS_FALLBACK entry needed.
        def tells_impl(name, &block)
          @operations << PortOperationBuilder.build(name, owner: @owner, direction: :inbound, &block)
        end

        # WHAT WE ASK OF THE OUTSIDE — the direction this language did not
        # have. Before this, a domain could be CALLED by an adapter and never
        # call one. An `asks` is dispatched like any other port operation, so
        # a `policy` can trigger it off an event, and it comes back as one of
        # the two events it named — which is what makes the outside world
        # something the model can reason about rather than a place exceptions
        # come from.
        #
        # RENAMED FROM `asks` — item #13's full metaprogrammed dispatch
        # (slice 4c), same reasoning as tells_impl above.
        def asks_impl(name, &block)
          @operations << PortOperationBuilder.build(name, owner: @owner, direction: :outbound, &block)
        end

        # THE DRIVEN HALF OF THE SAME WORD. `operation`/`emits` translates an
        # inbound fact into this domain's own event vocabulary — there is no
        # channel back to a caller beyond the events it emits. `verb` is the
        # opposite direction: the domain calling OUT to a swappable adapter
        # and getting a real value back (a checkout URL, a fetched document),
        # exactly what `Hecks.port "name" do verb "x" end` already builds —
        # this is that same `Port`, reached from the same `port` call
        # `operation` already lives under, so a project's own resource ports
        # read next to their binding instead of in a separate file. One port,
        # one shape or the other — never both.
        # `verb` — item #13's full metaprogrammed dispatch, slice 1
        # (whole-project table-unification survey): a bare, kind-driven
        # coerce-and-assign with nothing else, now executed by
        # `GenericDispatch`.

        def build
          raise Malformed, "#{@name} declares both a verb and operations — a port is one or the other, not both" if @verb && !@operations.empty?

          return Port.new(name: @name, verb: @verb, signal: :reply) if @verb

          raise Malformed, "#{@name} declares no verb and no operations" if @operations.empty?

          DomainPort.new(name: @name, operations: @operations)
        end

        def self.build(name, owner: nil, &block)
          builder = new(name, owner: owner)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
