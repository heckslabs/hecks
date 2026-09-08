require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # The `Hecks.adapter "Name" do port ...; field ...; secret ... end`
      # receiver — collects the port it implements plus its own settings
      # fields and secrets, then builds and judges an `Adapter` construct.
      class AdapterBuilder
        GRAMMAR_CONTEXT = "Adapter".freeze

        include WordGate

        def initialize(name)
          @name    = name
          @fields  = []
          @secrets = []
        end

        def port(value) = @port = value.to_s

        def field(name) = @fields << name.to_sym

        def secret(name) = @secrets << name.to_sym

        def build
          MetaValidator.call_adapter(Adapter.new(name: @name, port: @port, fields: @fields, secrets: @secrets))
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
