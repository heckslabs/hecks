require_relative "synthesizer"
require "tmpdir"
require "fileutils"

module Hecks
  module Bluebook
    # Boots a bluebook and dispatches synthesized calls against it, collecting every failure.
    # Catches what static checks miss, but not wrong answers, and naive values may trip invariants.
    module SmokeTest
      Failure = Struct.new(:domain, :aggregate, :command, :error, keyword_init: true) do
        def to_s = "#{domain}::#{aggregate}.#{command}: #{error}"
      end

      module_function

      # Boots an isolated copy of `dir` on Memory bindings, so real stores are never touched.
      # Skips the facade: its bare global constants would leak into the rest of the process.
      #
      # @param dir [String] path to a bootable hecks app directory — a saved
      #   domain, or a throwaway one rendered into a temp dir for this purpose
      # @return [Array<Failure>] every dispatch or query failure collected,
      #   empty when `dir` declares no bluebook or nothing failed
      def call(dir)
        Dir.mktmpdir("hecks-smoke-") do |scratch|
          isolate!(dir, scratch)
          dispatcher = Hecks.boot(scratch, install_facade: false)
          domain     = dispatcher.registry.bluebooks.keys.first
          next [] unless domain

          smoke_domain(dispatcher, domain)
        end
      end

      # Copies only the `.bluebook` files: a real `.world` carries settings keyed to its own
      # adapter and refuses under Memory.
      #
      # @param dir [String] path to the source hecks app directory to isolate
      # @param scratch [String] path to the throwaway directory to copy the
      #   `.bluebook` files into
      # @return [void]
      def isolate!(dir, scratch)
        source = Adapters::Folder.new.bluebook_directory(dir)
        target = File.join(scratch, "bluebook")
        FileUtils.mkdir_p(target)
        Dir.glob(File.join(source, "*.bluebook")).each { |file| FileUtils.cp(file, target) }
      end

      # Walks aggregates in declaration order so later ones can reference earlier `created` ids.
      # rubocop:disable-next Metrics/AbcSize
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the
      #   booted dispatcher to dispatch synthesized commands and queries through
      # @param domain [String] the domain name to smoke-test, a key of
      #   `dispatcher.registry.bluebooks`
      # @return [Array<Failure>] every dispatch or query failure collected, in
      #   declaration order; empty when `domain` names no loaded chapter or
      #   nothing failed
      def smoke_domain(dispatcher, domain)
        chapter = dispatcher.registry.bluebook(domain)
        return [] unless chapter

        created  = {}
        failures = []

        chapter.aggregates.each do |aggregate|
          creating, noncreating = aggregate.commands.partition(&:creates?)

          creating.each do |command|
            args = Synthesizer.args_for(chapter, aggregate, command, created)
            begin
              result = dispatcher.dispatch_flat("#{domain}::#{aggregate.name}.#{command.hecks_name}", args)
              created[aggregate.name] = result.instance.id
            rescue StandardError => e
              failures << Failure.new(domain: domain, aggregate: aggregate.name, command: command.hecks_name,
                                      error: "#{e.class}: #{e.message}")
              next
            end

            noncreating.each do |nc_command|
              nc_args = Synthesizer.args_for(chapter, aggregate, nc_command, created).merge(id: created[aggregate.name])
              dispatcher.dispatch_flat("#{domain}::#{aggregate.name}.#{nc_command.hecks_name}", nc_args)
            rescue StandardError => e
              failures << Failure.new(domain: domain, aggregate: aggregate.name, command: nc_command.hecks_name,
                                      error: "#{e.class}: #{e.message}")
            end
          end
        end

        chapter.read_models.each do |model|
          root_id = created[model.reference_target]
          # No root was created, so there is nothing to query yet.
          next unless root_id

          dispatcher.query("#{domain}.#{model.query_name}", model.reference_name => root_id)
        rescue StandardError => e
          failures << Failure.new(domain: domain, aggregate: model.name, command: "report(#{model.name})",
                                  error: "#{e.class}: #{e.message}")
        end

        failures
      end
    end
  end
end
