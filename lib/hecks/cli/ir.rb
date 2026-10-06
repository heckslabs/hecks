require_relative "../../hecks"
# ADR 0033 — a domain wired to PostgresEra needs this plugin loaded
# explicitly; the era/lineage subsystem does not load with core.
require_relative "../ports/persistence/plugins/era"

module Hecks
  module CLI
    # The command behind `hecks ir`: a booted domain's IR as JSON, the
    # same `to_h` the golden specs pin and `StorageShape` hashes into an era.
    module Ir
      module_function

      # Prints the IR `argv` asks for.
      #
      # `--meta` prints the language's own IR, reached through
      # `Bluebook::MetaValidator.grammar_registry`, the real boot sequence, so it
      # can't drift from what `MetaValidator` loads.
      #
      # @param argv [Array<String>] a domain path and `--translations`, or `--meta`
      # @param program [String] the name the usage message calls this command by
      # @param default_domain [String, nil] the domain booted when `argv` names none;
      #   nil makes a domain argument required
      # @return [void]
      # @raise [SystemExit] when no domain is named and there is no default
      def call(argv, program:, default_domain: nil)
        argv = argv.dup
        return print_meta if argv.delete("--meta")

        translations_only = argv.delete("--translations")
        domain = argv.shift || default_domain or abort "usage: #{program} <domain> [--translations] | #{program} --meta"
        registry = Hecks.boot(domain).registry
        puts(translations_only ? Projector::Exporter.translations_json(registry) : Projector::Exporter.json(registry))
      end

      # @api private
      def print_meta
        require_relative "../bluebook/meta_validator"
        puts Projector::Exporter.json(Bluebook::MetaValidator.grammar_registry)
      end
    end
  end
end
