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
          # Settings are read under the name the world declares; only the class follows the layout.
          settings = layout_settings(registry, domain, aggregate, bind, opts.settings_verb)
          adapter = registry.adapter_class(bind.adapter).new(aggregate: aggregate, settings: settings, root: registry.root)
          repository = AppendOnly.new(CodecBoundary.guard!(adapter))
          # `:atomic_append` (PostgresRevision) means `append` already committed the
          # projected state in the same transaction as the journal row, so a
          # boot-time replay through `project` has nothing left to fix up.
          opts.recover && !repository.capabilities.include?(:atomic_append) ? repository.recover! : repository
        end

        # A `Postgres` bind in a hecksagon that sets `revisions` builds the revision layout, which
        # is the `PostgresRevision` adapter until the layout is extracted (ADR 0182, delegation step).
        # Every other bind is returned unchanged.
        #
        # @param registry [Runtime::Registry] the booted registry
        # @param domain [String, Symbol] the domain the aggregate belongs to
        # @param bind [Bluebook::Bind] the bind as the hecksagon declared it
        # @return [Bluebook::Bind] the bind the adapter is built and configured under
        def revision_domain?(registry, domain, bind)
          bind.adapter.to_s == "Postgres" && registry.hecksagon(domain)&.revisions? == true
        end

        # The settings the adapter is built with: the declared ones, plus `revisions` where the
        # hecksagon selects the revision layout for a `Postgres` bind.
        #
        # @return [Hash] the settings for the adapter's constructor
        def layout_settings(registry, domain, aggregate, bind, settings_verb)
          settings = adapter_settings(registry, domain, aggregate, bind, settings_verb)
          return settings unless revision_domain?(registry, domain, bind)

          settings.merge(revisions: true)
        end

        # Checks the bind against the registry and gathers the settings its adapter is built with.
        #
        # @param registry [Runtime::Registry] the booted registry
        # @param domain [String, Symbol] the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate the adapter is built for
        # @param bind [Bluebook::Bind] the bind naming the adapter
        # @param settings_verb [String] the verb whose settings configure the adapter
        # @return [Hash] the declared settings, under the adapter's own declared defaults, plus
        #   the domain, resolved era, superseding era and whether the shape is unminted
        def adapter_settings(registry, domain, aggregate, bind, settings_verb)
          registry.check_verb(bind)
          settings = registry.binding_settings(domain, settings_verb, bind.adapter)
                             .reject { |key, _| key.to_sym == :role }
          registry.check_settings(bind, settings)
          settings = registry.with_adapter_defaults(bind.adapter, aggregate, settings)
          # domain, resolved era and superseding era ride along outside the declared
          # settings: a lineage adapter needs them to journal per domain, per-era.
          settings.merge(boot_marks(registry, domain))
        end

        # The per-domain marks the boot gate left on the registry, merged into an adapter's
        # settings.
        #
        # @return [Hash] the domain, resolved era, superseding era and whether the shape is unminted
        def boot_marks(registry, domain)
          name = domain.to_s
          { domain: name, era: registry.resolved_eras[name], superseded_by: registry.superseded_eras[name],
            unminted: registry.unminted_eras.key?(name) }
        end
      end
    end
  end
end
