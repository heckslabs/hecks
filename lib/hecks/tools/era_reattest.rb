# frozen_string_literal: true

require "hecks"
require "json"
require_relative "../tools"

module Hecks
  module Tools
    # Re-attests an era's held text after a digest-integrity refusal, once a human has read it.
    # Refuses without `--accept`; each attestation (old digest, new digest, when) is logged. The
    # digest is tamper-evidence against drift, not against an adversary.
    #
    #   bin/reattest_era <domain> <era ordinal> [--accept]
    module EraReattest
      USAGE = "usage: bin/reattest_era <domain> <era ordinal> [--accept]"

      module_function

      # Shows the held text against its recorded digest and, with `--accept`, re-freezes it.
      #
      # @param argv [Array<String>] the domain directory, the era's ordinal and `--accept`
      # @param root [String] unused: the domain is read from the path given
      # @return [Integer] 0 when nothing needed attesting or it was attested, 1 when refused
      # @raise [SystemExit] when the domain cannot be loaded or holds no such era
      def main(argv, **)
        argv = argv.dup
        accept = argv.delete("--accept")
        domain_path = argv.shift
        ordinal = argv.shift&.to_i
        abort USAGE unless domain_path && ordinal&.positive?

        registry, bluebook = load_domain(domain_path)
        lineage = open_lineage(registry, bluebook)
        era = lineage.raw_era(ordinal) or abort "#{bluebook.name} holds no era #{ordinal}"
        verify(bluebook, lineage, era, ordinal, accept)
      end

      # No translations are loaded: an unresolved edge must not block attesting a text.
      #
      # @param domain_path [String] the domain directory
      # @return [Array] the registry and its bluebook
      def load_domain(domain_path)
        loading = Hecks::Ports::Loading.bootstrap
        directory = loading.bluebook_directory(domain_path)
        registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(loading.shared_root(nil, directory))
          loading.load_each(directory, %w[*.port *.adapter *.bluebook *.hecksagon *.world])
        end
        bluebook = registry.bluebooks.values.first or abort "no bluebook in #{directory}"
        [registry, bluebook]
      end

      # @return [Object] the domain's ensured lineage
      # @raise [SystemExit] when the bound adapter holds no eras
      def open_lineage(registry, bluebook)
        first = bluebook.aggregates.first or abort "#{bluebook.name} declares no aggregates"
        adapter_name = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, first).adapter
        capable =
          begin
            adapter_class = registry.adapter_class(adapter_name)
            adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
          rescue StandardError
            false
          end
        # Only a lineage-capable adapter holds era texts.
        unless capable
          abort "#{bluebook.name} is bound to #{adapter_name}, which holds no eras — " \
                "there is no frozen text to re-attest."
        end

        settings = registry.world(bluebook.name)&.for_binding(Hecks::Ports::Persistence::VERB, adapter_name) || {}
        db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, settings)
        lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
        lineage.ensure_base!
        lineage
      end

      # @return [Integer] the exit status
      def verify(bluebook, lineage, era, ordinal, accept)
        text = era[:held_text]
        stored = era[:held_digest]
        computed = Digest::SHA256.hexdigest(text)
        if stored == computed
          puts "#{bluebook.name} era #{ordinal}: the held text matches its digest — nothing to re-attest."
          return 0
        end

        puts "#{bluebook.name} era #{ordinal}: the held text does NOT match its recorded digest."
        puts "  recorded: #{stored || '(none)'}"
        puts "  computed: #{computed}"
        return 1 unless shape_unchanged?(bluebook, era, ordinal, text)

        show(text)
        return refuse_without_accept unless accept

        fresh = lineage.reattest!(ordinal)
        puts
        puts "ATTESTED: era #{ordinal} re-frozen as #{fresh[0, 12]}… — the old and new digests are recorded."
        0
      end

      # A shape change refuses hard; no `--accept` passes it.
      #
      # @return [Boolean] false after printing the refusal
      def shape_unchanged?(bluebook, era, ordinal, text)
        stored_projection = era[:held_projection] && JSON.parse(era[:held_projection])
        verdict = Hecks::Translation::Reattest.shape_guard!(
          domain: bluebook.name, ordinal: ordinal, text: text,
          stored_hash: era[:hash], stored_projection: stored_projection
        )
        case verdict
        when :cosmetic
          puts "  shape:    unchanged — the edit is cosmetic (the text still projects to era #{ordinal}'s " \
               "minted name)"
        when :unnamed
          puts "  shape:    era #{ordinal} was never named, so no shape comparison is possible — read carefully"
        end
        true
      rescue Hecks::Runtime::WiringError => e
        puts
        puts "REFUSED: #{e.message}"
        false
      end

      # @return [void]
      def show(text)
        puts
        puts "The held text AS IT NOW STANDS — the original is gone; this is what you would be attesting to:"
        puts "─" * 72
        puts text
        puts "─" * 72
      end

      # @return [Integer] 1
      def refuse_without_accept
        puts
        puts "REFUSED: nothing changed. If you have read the text above and accept it as this era's"
        puts "frozen source, run again with --accept. The attestation (old digest, new digest, when)"
        puts "goes on the record either way you decide."
        1
      end
    end
  end
end
