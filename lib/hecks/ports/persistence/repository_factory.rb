require_relative "append_only"
require_relative "codec_boundary"

module Hecks
  module Ports
    module Persistence
      # Turns a declared adapter binding into a concrete repository, guarding every
      # adapter it builds (`CodecBoundary.guard!`) before `recover!` or anything else touches it.
      module RepositoryFactory
        module_function

        # The keywords `build` accepts; an unknown one raises ArgumentError.
        BuildOptions = Struct.new(:recover, :settings_verb, keyword_init: true) do
          def initialize(recover: true, settings_verb: VERB) = super
        end

        # Instantiates the adapter a bind names, guards it, and wraps it as a repository.
        #
        # @param registry [Runtime::Registry] the booted registry
        # @param domain [String, Symbol] the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate to persist
        # @param bind [Bluebook::Bind] the bind naming the adapter
        # @param ** [Hash] the options; `recover:` (default true) replays the journal at build time;
        #   `settings_verb:` (default `VERB`) names the verb whose settings configure the adapter
        # @return [Persistence::AppendOnly] the repository, recovered unless the adapter is atomic
        # @raise [ArgumentError] on an unknown option
        def build(registry, domain, aggregate, bind, **)
          opts = BuildOptions.new(**)
          settings = adapter_settings(registry, domain, bind, opts.settings_verb)
          adapter = registry.adapter_class(bind.adapter).new(aggregate: aggregate, settings: settings, root: registry.root)
          repository = AppendOnly.new(CodecBoundary.guard!(adapter))
          # `:atomic_append` (PostgresEra) means `append` already committed the
          # projected state in the same transaction as the journal row, so a
          # boot-time replay through `project` has nothing left to fix up.
          opts.recover && !repository.capabilities.include?(:atomic_append) ? repository.recover! : repository
        end

        # Checks the bind against the registry and gathers the settings its adapter is built with.
        #
        # @param registry [Runtime::Registry] the booted registry
        # @param domain [String, Symbol] the domain the aggregate belongs to
        # @param bind [Bluebook::Bind] the bind naming the adapter
        # @param settings_verb [String] the verb whose settings configure the adapter
        # @return [Hash] the declared settings plus the domain, resolved era and superseding era
        def adapter_settings(registry, domain, bind, settings_verb)
          registry.check_verb(bind)
          settings = registry.binding_settings(domain, settings_verb, bind.adapter)
                             .reject { |key, _| key.to_sym == :role }
          registry.check_settings(bind, settings)
          # domain, resolved era and superseding era ride along outside the declared
          # settings: a lineage adapter needs them to journal per domain, per-era.
          settings.merge(domain: domain.to_s, era: registry.resolved_eras[domain.to_s],
                         superseded_by: registry.superseded_eras[domain.to_s])
        end
      end
    end
  end
end
