require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class PortBuilder
        GRAMMAR_CONTEXT = "Port"

        include WordGate

        def initialize(name)
          @name   = name
          @signal = :reply
        end

        def verb(value)   = @verb = value.to_s
        def signal(value) = @signal = value.to_sym

        def build
          MetaValidator.call_port(Port.new(name: @name, verb: @verb, signal: @signal))
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
