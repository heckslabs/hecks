require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a top-level `.port` file's `Hecks.port "Name" do verb "x";
      # signal :effect end` body into a `Port` — the adapter-facing shape (one
      # verb, one signal, an optional method contract in `answers`) a domain
      # calls OUT through, as opposed to `DomainPortBuilder`'s own inbound/
      # outbound operations.
      class PortBuilder
        GRAMMAR_CONTEXT = "Port".freeze

        include WordGate

        def initialize(name)
          @name    = name
          @signal  = :reply
          @answers = []
        end

        def verb(value)   = @verb = value.to_s
        def signal(value) = @signal = value.to_sym

        # THE METHOD CONTRACT — the fact a `.port` file's `verb`/`signal`
        # never carried: what an adapter must actually RESPOND TO for a
        # dispatch to reach it without a bare `NoMethodError`. Declared the
        # same repeatable way `AdapterBuilder#field`/`#secret` already are,
        # so `verify!` can check it with `respond_to?` at boot instead of
        # the runtime discovering it live.
        def answers(name) = @answers << name.to_sym

        def build
          MetaValidator.call_port(Port.new(name: @name, verb: @verb, signal: @signal, answers: @answers))
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
