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

        # @param name [String] the adapter's name, as written after `Hecks.adapter`
        def initialize(name)
          @name    = name
          @fields  = []
          @secrets = []
        end

        # Names the port this adapter implements; a repeated call replaces the earlier name.
        #
        # @param value [String, Symbol] the port's name, such as `"CI"` or `"agent"`
        # @return [String] the port name as stored
        def port(value) = @port = value.to_s

        # Declares one plain setting a `.world` file may supply for this adapter.
        #
        # @param name [Symbol, String] the setting's name, such as `:database`
        # @return [Array<Symbol>] every field declared so far, this one last
        def field(name) = @fields << name.to_sym

        # Declares one setting whose value is a secret, such as an API token.
        #
        # @param name [Symbol, String] the secret's name, such as `:api_token`
        # @return [Array<Symbol>] every secret declared so far, this one last
        def secret(name) = @secrets << name.to_sym

        # Assembles the collected port, fields and secrets, judged by the adapter language.
        #
        # @return [Bluebook::Adapter] the adapter, returned once the language accepts it
        # @raise [Bluebook::DSL::Malformed] if the adapter language refuses the declaration
        def build
          MetaValidator.call_adapter(Adapter.new(name: @name, port: @port, fields: @fields, secrets: @secrets))
        end

        # Evaluates an `Hecks.adapter` block against a fresh builder and returns what it built.
        #
        # @param name [String] the adapter's name
        # @yield the adapter body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Adapter] the judged adapter
        # @raise [Bluebook::DSL::Malformed] if the adapter language refuses the declaration, or
        #   the block uses a word the `Adapter` grammar does not admit
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
