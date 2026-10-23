require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # The `Hecks.adapter "Name" do port ...; field ...; secret ... end`
      # receiver — collects the port it implements plus its own settings
      # fields and secrets, then builds and judges an `Adapter` construct.
      class AdapterBuilder
        GRAMMAR_CONTEXT = "Adapter".freeze

        # Marks a field that gives no `default:`; `nil` and `false` are defaults too.
        NO_DEFAULT = Object.new.freeze

        include WordGate

        # @param name [String] the adapter's name, as written after `Hecks.adapter`
        # @param source_dir [String, nil] the directory of the `.adapter` file, which a plugin's
        #   `runs` path is read against
        def initialize(name, source_dir: nil)
          @name = name
          @source_dir = source_dir
          @fields   = []
          @secrets  = []
          @defaults = {}
          @answers  = []
        end

        # Names the port this adapter implements; a repeated call replaces the earlier name.
        #
        # @param value [String, Symbol] the port's name, such as `"CI"` or `"agent"`
        # @return [String] the port name as stored
        def port(value) = @port = value.to_s

        # Declares one plain setting a `.world` file may supply for this adapter.
        #
        # @param name [Symbol, String] the setting's name, such as `:database`
        # @param default [Object] the value used when the world gives none; a string may hold
        #   `{name}` or `{storage_name}`, filled from the aggregate the adapter is built for
        # @return [Array<Symbol>] every field declared so far, this one last
        def field(name, default: NO_DEFAULT)
          @defaults[name.to_sym] = default unless default.equal?(NO_DEFAULT)
          @fields << name.to_sym
        end

        # Declares one setting whose value is a secret, such as an API token.
        #
        # @param name [Symbol, String] the secret's name, such as `:api_token`
        # @return [Array<Symbol>] every secret declared so far, this one last
        def secret(name) = @secrets << name.to_sym

        # Names one query this adapter answers, qualified by its chapter and aggregate.
        #
        # @param name [String] the query, such as `"Calendar::Event.Occurrences"`
        # @return [Array<String>] every query named so far, this one last
        def answers_query(name) = @answers << name.to_s

        # Names the wasm module this adapter runs, beside its `.adapter` file.
        #
        # @param file [String] the module's file name, such as `"occurrences.wasm"`
        # @return [String] the file name as stored
        def runs(file) = @runs = file.to_s

        # Assembles the collected port, fields, defaults, secrets and plugin, judged by the adapter
        # language.
        #
        # @return [Bluebook::Adapter] the adapter, returned once the language accepts it
        # @raise [Bluebook::DSL::Malformed] if the adapter language refuses the declaration
        def build
          MetaValidator.call_adapter(
            Adapter.new(name: @name, port: @port, fields: @fields, secrets: @secrets, defaults: @defaults,
                        answers: @answers, runs: @runs, source_dir: @source_dir)
          )
        end

        # Evaluates an `Hecks.adapter` block against a fresh builder and returns what it built.
        #
        # @param name [String] the adapter's name
        # @yield the adapter body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Adapter] the judged adapter
        # @raise [Bluebook::DSL::Malformed] if the adapter language refuses the declaration, or
        #   the block uses a word the `Adapter` grammar does not admit
        def self.build(name, &block)
          builder = new(name, source_dir: block && File.dirname(block.source_location.first))
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
