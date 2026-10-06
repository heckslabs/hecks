require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `domain_port "Name" do ... end` block into a `DomainPort` of inbound (`tells`)
      # and outbound (`asks`) operations, or a plain `Port` when the body is bare-verb shaped.
      class DomainPortBuilder
        GRAMMAR_CONTEXT = "DomainPort".freeze

        include WordGate

        # Only the top-level `Hecks.port` passes `legacy_bare_port: true`, so its empty body builds
        # a verbless `Port`. Aggregate-scoped and hecksagon-root callers keep the stricter refusal.
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
          @answered_queries = []
          @legacy_bare_port = legacy_bare_port
        end

        # Declares an inbound operation: a fact the outside world delivers to this domain.
        #
        # Spelled `operation` or `tells`; both route here through the keyword table.
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
        # Dispatched like any port operation, so a `policy` can trigger it off an event; it comes
        # back as one of the two events it named.
        #
        # @param name [String] the operation's name
        # @param to [Symbol, String, Module, nil] the aggregate the operation routes to, or nil
        # @yield the operation body (`attribute`, `answers`, `refuses`), evaluated against a
        #   `PortOperationBuilder`
        # @return [Array<Bluebook::PortOperation>] every operation declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if the body declares `emits`, or lacks either
        #   `answers` or `refuses`
        def asks_impl(name, to: nil, &)
          @operations << PortOperationBuilder.build(name, to: to, owner: @owner, direction: :outbound, &)
        end

        # Declares that this port's adapter answers one of the owning aggregate's queries.
        #
        # The bluebook declares the question and the shape of its answer (`returns`) and never
        # says who answers it; this binds it. The adapter is asked by the query's snake-cased
        # name with its arguments. The aggregate's stored records are never read.
        #
        # @param name [String] the query's name, as the aggregate declares it
        # @param removed [Hash] any keyword at all; the binding takes only the name
        # @return [Array<Bluebook::QueryAnswer>] every binding declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if a keyword such as `shape:` is written, or the query
        #   is already bound on this port
        def answers_query_impl(name, **removed)
          unless removed.empty?
            raise Malformed, "answers_query #{name.inspect} takes only the query's name — the shape " \
                             "of its answer is the query's own `returns`, declared in the bluebook " \
                             "(#{removed.keys.join(", ")} is not a word here)"
          end
          if @answered_queries.any? { |answer| answer.name == name.to_s }
            raise Malformed, "#{@name} binds #{name} twice — a query has one answer"
          end

          @answered_queries << QueryAnswer.new(name: name)
        end

        # Names the verb aggregates call this port by, making it a driven `Port` rather than a
        # `DomainPort` of operations. A port is one shape or the other, never both.
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
        # The bare-verb fallback carries it onto the `Port`, as `PortBuilder#answers` does.
        #
        # @param name [Symbol, String] the method name, such as `:canonical`
        # @return [Array<Symbol>] every method declared so far, this one last
        def answers(name) = @answers << name.to_sym

        # Assembles whichever of the two port shapes the body declared.
        #
        # @return [Bluebook::Port, Bluebook::DomainPort] a `Port` when the body named a `verb`
        #   (or was empty under `legacy_bare_port:`), otherwise a `DomainPort` of its operations
        #   and answered queries
        # @raise [Bluebook::DSL::Malformed] if the body declares both a verb and operations,
        #   declares neither without `legacy_bare_port:`, or the port language refuses the `Port`
        def build
          refuse_verb_and_operations!
          return build_verb_port if @verb || (@legacy_bare_port && @operations.empty?)

          raise Malformed, "#{@name} declares no verb and no operations, and answers no query" if body_empty?

          DomainPort.new(name: @name, operations: @operations, answered_queries: @answered_queries)
        end

        # Evaluates a `port` block against a fresh builder and returns whichever shape it declared.
        #
        # @param name [String] the port's name
        # @param owner [String, nil] the aggregate the port is declared on, or nil
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

        private

        def body_empty? = @operations.empty? && @answered_queries.empty?

        def refuse_verb_and_operations!
          return unless @verb && !body_empty?

          raise Malformed,
                "#{@name} declares both a verb and operations — a port is one or the other, not both"
        end

        def build_verb_port
          MetaValidator.call_port(Port.new(name: @name, verb: @verb, signal: @signal, answers: @answers))
        end
      end
    end
  end
end
