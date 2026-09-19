require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `verb "x"; signal :effect` port body into a `Port` — the
      # adapter-facing shape (one verb, one signal, an optional method
      # contract in `answers`) a domain calls out through, as opposed to
      # `DomainPortBuilder`'s own inbound/outbound operations.
      #
      # `Hecks.port` (lib/hecks.rb) parses a top-level `.port` file through
      # `DomainPortBuilder`, whose bare-verb branch builds the identical
      # `Port`; this builder is the reference shape `spec/dsl_spec.rb` holds
      # that branch to.
      class PortBuilder
        GRAMMAR_CONTEXT = "Port".freeze

        include WordGate

        # @param name [String] the port's name, as written after `Hecks.port`
        def initialize(name)
          @name    = name
          @signal  = :reply
          @answers = []
        end

        # Names the verb a domain's aggregates call this port by when a hecksagon binds it.
        #
        # @param value [String, Symbol] the verb, such as `"asked_by"` or `"persisted_by"`
        # @return [String] the verb as stored
        def verb(value)   = @verb = value.to_s

        # Sets whether the domain waits for a value back; a port left unset signals `:reply`.
        #
        # @param value [Symbol, String] `:reply` when the adapter answers with a value,
        #   `:effect` when it is called only for its effect
        # @return [Symbol] the signal as stored
        def signal(value) = @signal = value.to_sym

        # Declares one method an adapter bound to this port must respond to.
        #
        # **The method contract** — the fact a `.port` file's `verb`/`signal`
        # never carried: what an adapter must actually respond to for a
        # dispatch to reach it without a bare `NoMethodError`. Declared the
        # same repeatable way `AdapterBuilder#field`/`#secret` already are,
        # so `verify!` can check it with `respond_to?` at boot instead of
        # the runtime discovering it live.
        #
        # @param name [Symbol, String] the method name, such as `:ask`
        # @return [Array<Symbol>] every method declared so far, this one last
        def answers(name) = @answers << name.to_sym

        # Assembles the collected verb, signal and method contract, judged by the port language.
        #
        # @return [Bluebook::Port] the port, returned once the language accepts it
        # @raise [Bluebook::DSL::Malformed] if the port language refuses the declaration
        def build
          MetaValidator.call_port(Port.new(name: @name, verb: @verb, signal: @signal, answers: @answers))
        end

        # Evaluates a port block against a fresh builder and returns what it built.
        #
        # @param name [String] the port's name
        # @yield the port body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Port] the judged port
        # @raise [Bluebook::DSL::Malformed] if the port language refuses the declaration, or
        #   the block uses a word the `Port` grammar does not admit
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
