require_relative "../../hecks"
# ADR 0033 — a domain wired to PostgresEra needs this plugin loaded
# explicitly; the era/lineage subsystem does not load with core.
require_relative "../ports/persistence/plugins/era"

module Hecks
  module CLI
    # The command behind `bin/ir` and `hecks ir`: a booted domain's IR as JSON, the
    # same `to_h` the golden specs pin and `StorageShape` hashes into an era, for
    # reading rather than asserting on.
    module Ir
      module_function

      # Prints the IR `argv` asks for.
      #
      # `--meta` prints the language's own IR, the chapters under
      # `lib/hecks/language/bluebook/` merged into one. It is reached through
      # `Bluebook::MetaValidator.grammar_registry`, the real boot sequence, so it
      # cannot drift from what `MetaValidator` itself loads.
      #
      # @param argv [Array<String>] a domain path and `--translations`, or `--meta`
      # @param program [String] the name the usage message calls this command by
      # @param default_domain [String, nil] the domain booted when `argv` names none;
      #   nil makes a domain argument required
      # @return [void]
      # @raise [SystemExit] when no domain is named and there is no default
      def call(argv, program:, default_domain: nil)
        argv = argv.dup
        if argv.delete("--meta")
          require_relative "../bluebook/meta_validator"
          puts Projector::Exporter.json(Bluebook::MetaValidator.grammar_registry)
          return
        end

        translations_only = argv.delete("--translations")
        domain = argv.shift || default_domain or abort "usage: #{program} <domain> [--translations] | #{program} --meta"
        runtime = Hecks.boot(domain)

        if translations_only
          puts Projector::Exporter.translations_json(runtime.registry)
        else
          puts Projector::Exporter.json(runtime.registry)
        end
      end
    end
  end
end
