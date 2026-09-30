# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Tail-merge: interleaves the old world's post-cut writes into the live head by their recorded
    # global ordinals, in one transaction.
    #
    # A record touched by both worlds since the cut refuses until it has an explicit winner:
    #
    #   bin/merge_tail <domain> [--winner <id>=old] [--winner <id>=new] ...
    module TailMerge
      USAGE = "usage: bin/merge_tail <domain> [--winner <id>=old|new] ..."

      module_function

      # Merges the tail and prints how many writes it interleaved.
      #
      # @param argv [Array<String>] the domain directory and any `--winner <id>=old|new`
      # @param root [String] unused: the domain is read from the path given
      # @return [Integer] 0
      # @raise [SystemExit] when the arguments are malformed, the domain cannot be loaded, or the
      #   merge is refused
      def main(argv, **)
        domain_path, winners = parse(argv.dup)
        registry, bluebook = load_domain(domain_path)
        settings = lineage_settings(registry, bluebook)
        report_divergence(bluebook, settings)

        begin
          Hecks::Adapters::PostgresEra::LineageManager.merge!(
            registry: registry, bluebook: bluebook, settings: settings, winners: winners
          )
        rescue Hecks::Runtime::WiringError => e
          abort "REFUSED: #{e.message}"
        end

        puts "merged — the head now interleaves both worlds by their recorded ordinals"
        winners.each { |id, side| puts "  winner #{id}=#{side} appended as the newest row" }
        0
      end

      # @return [Array] the domain directory and the winners by record id
      def parse(argv)
        domain_path = nil
        winners = {}
        until argv.empty?
          argument = argv.shift
          if argument == "--winner"
            declaration = argv.shift or abort "--winner needs <id>=old|new"
            id, side = declaration.split("=", 2)
            abort "--winner #{declaration}: the side must be `old` or `new`" unless %w[old new].include?(side)
            winners[id] = side
          else
            domain_path = argument
          end
        end
        abort USAGE unless domain_path
        [domain_path, winners]
      end

      # @param domain_path [String] the domain directory
      # @return [Array] the registry and its bluebook
      def load_domain(domain_path)
        loading = Hecks::Ports::Loading.bootstrap
        directory = loading.bluebook_directory(domain_path)
        registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
        begin
          Hecks.with_registry(registry) do
            loading.load_library
            loading.load_project(loading.shared_root(nil, directory))
            loading.load_domain(directory)
          end
        rescue Hecks::Bluebook::DSL::Malformed => e
          abort "REFUSED at load: #{e.message}"
        end
        bluebook = registry.bluebooks.values.first or abort "no bluebook in #{directory}"
        [registry, bluebook]
      end

      # @return [Hash] the persistence binding's settings
      # @raise [SystemExit] when the bound adapter is not lineage-capable
      def lineage_settings(registry, bluebook)
        first = bluebook.aggregates.first or abort "#{bluebook.name} declares no aggregates"
        adapter_name = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, first).adapter
        capable =
          begin
            adapter_class = registry.adapter_class(adapter_name)
            adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
          rescue StandardError
            false
          end
        unless capable
          abort "a tail-merge needs a lineage journal; #{bluebook.name} is bound to #{adapter_name}, " \
                "not PostgresEra"
        end

        registry.binding_settings(bluebook.name, Hecks::Ports::Persistence::VERB, adapter_name)
      end

      # @return [void]
      def report_divergence(bluebook, settings)
        db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, settings)
        lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
        lineage.ensure_base!
        eras = lineage.eras
        diverged = eras.size > 1 ? (1...eras.last[:ordinal]).sum { |era| lineage.diverged_count(era) } : 0
        db.close

        puts "#{bluebook.name}: #{diverged} post-cut write#{'s' unless diverged == 1} " \
             "in ancestor eras before the merge"
      end
    end
  end
end
