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

        # `legacy_bare_port:` — only `Hecks.port`'s own top-level method
        # (lib/hecks.rb) passes `true`. `PortBuilder#build` never refused
        # an empty build (no verb, no signal, nothing) — `Port.new(verb:
        # nil, signal: :reply)` is a real, allowed shape dsl_spec.rb's own
        # "a port" tests rely on (`signal`-only, no `verb` at all). The
        # aggregate-scoped (`BindingProxy#port`) and hecksagon-root
        # (`HecksagonBuilder#port_impl`) callers both reach this same
        # class with `owner: nil` too when they're building the bare-verb
        # shape (`port_impl`'s own root-level port can be either shape,
        # decided only after `build` returns) — so `owner.nil?` cannot be
        # the discriminator between "old Hecks.port semantics" and "real
        # DomainPort semantics"; those two callers correctly want the
        # stricter "declares no verb and no operations" refusal `build`
        # already raises below, unchanged. Only the literal top-level
        # `.port` file caller wants the older, looser rule.
        #
        # @param name [String] the port's name
        # @param owner [String, nil] name of the aggregate the port is declared on, handed to
        #   each operation's builder; nil for a root-level or top-level port
        # @param legacy_bare_port [Boolean] true only for `Hecks.port`: an empty body then builds
        #   a verbless `Port` rather than being refused
        def initialize(name, owner: nil, legacy_bare_port: false)
          @name             = name
          @owner            = owner
          @operations       = []
          @signal           = :reply
          @answers          = []
          @legacy_bare_port = legacy_bare_port
        end

        # Declares an inbound operation: a fact the outside world delivers to this domain.
        #
        # **What the outside tells us** — an external fact arriving, translated
        # into this domain's own word for it. Spelled `operation` or `tells`;
        # `operation` stays because the corpus is full of it, and renaming
        # a word costs every chapter that uses it for no gain a reader can
        # feel.
        #
        # Answers both words — item #13's full metaprogrammed dispatch
        # (slice 4c). `operation`/`tells` are two separate Keyword rows
        # (a word admitting two forms) that both name `calls: "tells_impl"`
        # — the routing between the two spellings lives in the table,
        # not in a Ruby `alias`. Not bootstrap-reachable (checked
        # directly), so its `BOOTSTRAP_CALLS_FALLBACK` row is never consulted.
        #
        # @param name [String] the operation's name, such as `"PaymentSettled"`
        # @param to [Symbol, String, Module, nil] the aggregate the operation routes to, written
        #   as a bare constant; nil leaves routing to the operation's own attributes
        # @yield the operation body (`attribute`, `emits`), evaluated against a
        #   `PortOperationBuilder`
        # @return [Array<Bluebook::PortOperation>] every operation declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if the body declares no `emits`, or uses `answers` or
        #   `refuses`, which belong to an `asks`
        def tells_impl(name, to: nil, &)
          @operations << PortOperationBuilder.build(name, to: to, owner: @owner, direction: :inbound, &)
        end

        # Declares an outbound operation: a question this domain puts to the outside world.
        #
        # **What we ask of the outside** — the direction that lets a domain
        # call an adapter, not only be called by one. An `asks` is dispatched
        # like any other port operation, so
        # a `policy` can trigger it off an event, and it comes back as one of
        # the two events it named — which is what makes the outside world
        # something the model can reason about rather than a place exceptions
        # come from.
        #
        # Answers the `asks` word through the table's `calls:` column — item
        # #13's full metaprogrammed dispatch (slice 4c), same reasoning as
        # `tells_impl` above.
        #
        # @param name [String] the operation's name
        # @param to [Symbol, String, Module, nil] the aggregate the operation routes to, written
        #   as a bare constant; nil leaves routing to the operation's own attributes
        # @yield the operation body (`attribute`, `answers`, `refuses`), evaluated against a
        #   `PortOperationBuilder`
        # @return [Array<Bluebook::PortOperation>] every operation declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if the body declares `emits`, or lacks either
        #   `answers` or `refuses`
        def asks_impl(name, to: nil, &)
          @operations << PortOperationBuilder.build(name, to: to, owner: @owner, direction: :outbound, &)
        end

        # The driven half of the same word. `operation`/`emits` translates an
        # inbound fact into this domain's own event vocabulary — there is no
        # channel back to a caller beyond the events it emits. `verb` is the
        # opposite direction: the domain calling out to a swappable adapter
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

        # Names the verb aggregates call this port by, which makes it a driven `Port` rather than
        # a `DomainPort` of operations.
        #
        # `Hecks.port "x" do verb "y"; signal :effect end`'s own two words,
        # reachable here too — a bare-verb `DomainPortBuilder.build` falls
        # back to the same `Port` object `PortBuilder` produces (`build`,
        # below), so any `.port` file can migrate to being parsed by this
        # builder with zero change to its own text, or to any caller that
        # reads `.verb`/`.signal` off the `Port` it gets back. Ordinary
        # `def`s, exactly like `PortBuilder`'s own — `WordGate`'s own
        # header is explicit that a word answered this way never reaches
        # its `method_missing`, so no new self-hosted grammar row is
        # needed for either word under this context.
        #
        # @param value [String, Symbol] the verb, such as `"charged_by"`
        # @return [String] the verb as stored
        def verb(value)   = @verb = value.to_s

        # Sets whether a verb-shaped port hands a value back; one left unset signals `:reply`.
        #
        # @param value [Symbol, String] `:reply` when the adapter answers with a value,
        #   `:effect` when it is called only for its effect
        # @return [Symbol] the signal as stored
        def signal(value) = @signal = value.to_sym

        # Declares one method an adapter bound to a verb-shaped port must respond to.
        #
        # **The method contract** — `PortBuilder#answers`'s own twin: a
        # `.port` file parsed through this builder (the repoint
        # `lib/hecks.rb#port`'s own comment describes) can declare one
        # (`extraction.port`'s own
        # `answers :canonical`, real, live corpus text) — this builder's
        # bare-verb fallback needs to carry it through to the same `Port`
        # object `PortBuilder` itself would have built, or the migration
        # would silently drop a method-contract check for any `.port`
        # file that uses this word.
        #
        # @param name [Symbol, String] the method name, such as `:canonical`
        # @return [Array<Symbol>] every method declared so far, this one last
        def answers(name) = @answers << name.to_sym

        # Assembles whichever of the two port shapes the body declared.
        #
        # @return [Bluebook::Port, Bluebook::DomainPort] a `Port` when the body named a `verb`
        #   (or was empty under `legacy_bare_port:`), otherwise a `DomainPort` of its operations
        # @raise [Bluebook::DSL::Malformed] if the body declares both a verb and operations,
        #   declares neither without `legacy_bare_port:`, or the port language refuses the `Port`
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

        # Evaluates a `port` block against a fresh builder and returns whichever shape it declared.
        #
        # @param name [String] the port's name
        # @param owner [String, nil] name of the aggregate the port is declared on, or nil for a
        #   root-level or top-level port
        # @param legacy_bare_port [Boolean] true only for `Hecks.port`, which lets an empty body
        #   build a verbless `Port`
        # @yield the port body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Port, Bluebook::DomainPort] a verb-shaped `Port`, or a `DomainPort`
        #   holding the declared operations
        # @raise [Bluebook::DSL::Malformed] if the body declares both shapes, declares neither
        #   without `legacy_bare_port:`, holds an operation its builder refuses, or uses a word
        #   the `DomainPort` grammar does not admit
        def self.build(name, owner: nil, legacy_bare_port: false, &block)
          builder = new(name, owner: owner, legacy_bare_port: legacy_bare_port)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
