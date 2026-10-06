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

      # One smoke run: what is being dispatched through, which ids earlier commands minted, and
      # the failures collected so far.
      Run = Struct.new(:dispatcher, :domain, :chapter, :created, :failures)

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
          dispatcher = Hecks.boot(scratch, install_doors: false)
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

        run = Run.new(dispatcher, domain, chapter, {}, [])
        chapter.aggregates.each { |aggregate| smoke_aggregate(run, aggregate) }
        chapter.read_models.each { |model| smoke_read_model(run, model) }
        run.failures
      end

      # Dispatches every creating command, then, after each that succeeds, every other command.
      def smoke_aggregate(run, aggregate)
        creating, noncreating = aggregate.commands.partition(&:creates?)

        creating.each do |command|
          args = Synthesizer.args_for(run.chapter, aggregate, command, run.created)
          next unless smoke_created?(run, aggregate, command, args)

          noncreating.each { |other| smoke_other(run, aggregate, other) }
        end
      end

      # @return [Boolean] whether the creating command dispatched; a refusal is recorded instead
      def smoke_created?(run, aggregate, command, args)
        result = run.dispatcher.dispatch_flat("#{run.domain}::#{aggregate.name}.#{command.hecks_name}", args)
        run.created[aggregate.name] = result.instance.id
        true
      rescue StandardError => e
        record_failure(run, aggregate.name, command.hecks_name, e)
        false
      end

      # Dispatches a command against the instance the creating command made; a refusal is recorded.
      def smoke_other(run, aggregate, command)
        args = Synthesizer.args_for(run.chapter, aggregate, command, run.created).merge(id: run.created[aggregate.name])
        run.dispatcher.dispatch_flat("#{run.domain}::#{aggregate.name}.#{command.hecks_name}", args)
      rescue StandardError => e
        record_failure(run, aggregate.name, command.hecks_name, e)
      end

      # Queries a read model once its root exists; a refusal is recorded.
      def smoke_read_model(run, model)
        root_id = run.created[model.reference_target]
        # No root was created, so there is nothing to query yet.
        return unless root_id

        run.dispatcher.query("#{run.domain}.#{model.query_name}", model.reference_name => root_id)
      rescue StandardError => e
        record_failure(run, model.name, "report(#{model.name})", e)
      end

      # @return [Array<Failure>] `run.failures`, now holding one more
      def record_failure(run, aggregate_name, command_name, error)
        run.failures << Failure.new(domain: run.domain, aggregate: aggregate_name, command: command_name,
                                    error: "#{error.class}: #{error.message}")
      end
    end
  end
end
