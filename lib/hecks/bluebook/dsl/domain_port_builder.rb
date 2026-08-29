require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `domain_port "Name" do ... end` block into a `DomainPort` —
      # the inbound (`operation`/`tells`) and outbound (`asks`) operations a
      # domain exchanges with the outside world. Falls back to building a
      # plain `Port` (the same object `PortBuilder` builds) when the block is
      # bare-verb shaped instead, so an existing top-level `.port` file can
      # migrate to being parsed by this builder — see `legacy_bare_port:`'s
      # own comment on `#initialize`.
      class DomainPortBuilder
        GRAMMAR_CONTEXT = "DomainPort".freeze

        include WordGate

        # `legacy_bare_port:` — ONLY `Hecks.port`'s own top-level method
        # (lib/hecks.rb) passes `true`. `PortBuilder#build` never refused
        # an empty build (no verb, no signal, nothing) — `Port.new(verb:
        # nil, signal: :reply)` is a real, allowed shape dsl_spec.rb's own
        # "a port" tests rely on (`signal`-only, no `verb` at all). The
        # AGGREGATE-scoped (`BindingProxy#port`) and hecksagon-ROOT
        # (`HecksagonBuilder#port_impl`) callers both reach this SAME
        # class with `owner: nil` too when they're building the bare-verb
        # shape (`port_impl`'s own root-level port can be EITHER shape,
        # decided only after `build` returns) — so `owner.nil?` cannot be
        # the discriminator between "old Hecks.port semantics" and "real
        # DomainPort semantics"; those two callers correctly want the
        # stricter "declares no verb and no operations" refusal `build`
        # already raises below, unchanged. Only the literal top-level
        # `.port` file caller wants the older, looser rule.
        def initialize(name, owner: nil, legacy_bare_port: false)
          @name             = name
          @owner            = owner
          @operations       = []
          @signal           = :reply
          @answers          = []
          @legacy_bare_port = legacy_bare_port
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
        def tells_impl(name, to: nil, &)
          @operations << PortOperationBuilder.build(name, to: to, owner: @owner, direction: :inbound, &)
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
        def asks_impl(name, to: nil, &)
          @operations << PortOperationBuilder.build(name, to: to, owner: @owner, direction: :outbound, &)
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

        # `Hecks.port "x" do verb "y"; signal :effect end`'s own two words,
        # reachable here too — a bare-verb `DomainPortBuilder.build` falls
        # back to the SAME `Port` object `PortBuilder` produces (`build`,
        # below), so any `.port` file can migrate to being parsed by this
        # builder with zero change to its own text, or to any caller that
        # reads `.verb`/`.signal` off the `Port` it gets back. Ordinary
        # `def`s, exactly like `PortBuilder`'s own — `WordGate`'s own
        # header is explicit that a word answered this way never reaches
        # its `method_missing`, so no new self-hosted grammar row is
        # needed for either word under this context.
        def verb(value)   = @verb = value.to_s
        def signal(value) = @signal = value.to_sym

        # THE METHOD CONTRACT — `PortBuilder#answers`'s own twin, added
        # here after the fact: a `.port` file migrated to parse through
        # this builder (the repoint `lib/hecks.rb#port`'s own comment
        # describes) can still declare one (`extraction.port`'s own
        # `answers :canonical`, real, live corpus text) — this builder's
        # bare-verb fallback needs to carry it through to the same `Port`
        # object `PortBuilder` itself would have built, or the migration
        # would silently drop a method-contract check for any `.port`
        # file that uses this word.
        def answers(name) = @answers << name.to_sym

        def build
          if @verb && !@operations.empty?
            raise Malformed,
                  "#{@name} declares both a verb and operations — a port is one or the other, not both"
          end

          if @verb || (@legacy_bare_port && @operations.empty?)
            return MetaValidator.call_port(Port.new(name: @name, verb: @verb, signal: @signal,
                                                    answers: @answers))
          end

          raise Malformed, "#{@name} declares no verb and no operations" if @operations.empty?

          DomainPort.new(name: @name, operations: @operations)
        end

        def self.build(name, owner: nil, legacy_bare_port: false, &block)
          builder = new(name, owner: owner, legacy_bare_port: legacy_bare_port)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
