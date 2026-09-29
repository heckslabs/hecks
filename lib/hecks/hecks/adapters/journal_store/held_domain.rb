# frozen_string_literal: true

require_relative "../../../../hecks"
require_relative "../../../ports/persistence/plugins/era"

module Hecks
  module Adapters
    class JournalStore
      # A domain directory loaded the way the era tools load it, with the journal store its first
      # aggregate is bound to.
      #
      # `translated` loads the whole domain, translation edges included; `bare` loads the
      # bluebooks, hecksagons and worlds only, so an edge that does not resolve cannot stop a
      # text from being attested; `scaffold` loads everything but the edges, since an unresolved
      # edge file refuses to load and writing it is the point.
      class HeldDomain
        MODES = %i[translated bare scaffold].freeze

        attr_reader :registry, :bluebook, :directory, :adapter_name

        # Loads a domain and finds where its eras would be held.
        #
        # @param path [String] the domain directory, or the project holding its `bluebook/`
        # @param mode [Symbol] one of `MODES`
        # @return [HeldDomain] the loaded domain
        # @raise [Runtime::NotFound] if the directory does not exist, declares no bluebook, or
        #   does not load
        def self.open(path, mode: :translated)
          raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

          loading = Ports::Loading.bootstrap
          directory = loading.bluebook_directory(path)
          registry = Runtime::Registry.new(root: File.dirname(directory))
          load_into(registry, loading, directory, mode)
          new(registry, directory)
        rescue Errno::ENOENT
          raise Runtime::NotFound, "no such domain #{path.inspect}"
        rescue Bluebook::DSL::Malformed => e
          raise Runtime::NotFound, "REFUSED at load: #{e.message}"
        end

        # @api private
        def self.load_into(registry, loading, directory, mode)
          environment = ENV.fetch("HECKS_PROJECT_ENVIRONMENT", nil)
          Hecks.with_registry(registry) do
            loading.load_library
            loading.load_project(loading.shared_root(nil, directory))
            case mode
            when :translated then loading.load_domain(directory, environment: environment)
            when :bare then loading.load_each(directory, %w[*.port *.adapter *.bluebook *.hecksagon *.world])
            else load_scaffold(loading, directory, environment)
            end
          end
        end

        # @api private
        def self.load_scaffold(loading, directory, environment)
          loading.load_each(directory, %w[*.port *.adapter])
          loading.load_bluebooks(directory)
          loading.load_each(directory, %w[*.hecksagon *.world])
          return unless environment

          loading.load_each(directory, [File.join("environments", "#{environment}.hecksagon")])
          loading.load_each(directory, [File.join("environments", "#{environment}.world")])
        end

        # @param registry [Runtime::Registry] the loaded registry
        # @param directory [String] the domain's bluebook directory
        # @raise [Runtime::NotFound] if the registry holds no bluebook, or a bluebook no aggregate
        def initialize(registry, directory)
          @registry = registry
          @directory = directory
          @bluebook = registry.bluebooks.values.first or raise Runtime::NotFound, "no bluebook in #{directory}"
          first = @bluebook.aggregates.first or raise Runtime::NotFound, "#{@bluebook.name} declares no aggregates"
          @adapter_name = Ports::Persistence::BindingPolicy.resolve(registry, @bluebook.name, first).adapter
        end

        # Whether the store the domain is bound to keeps eras (`EraCheck`'s own question).
        #
        # @return [Boolean] true when the adapter is lineage capable
        def capable? = Runtime::EraCheck.lineage_capable?(registry, adapter_name)

        # Explains, as a refusal, why a domain has no eras.
        #
        # @return [String] the sentence
        def incapable_reason = "#{bluebook.name} is bound to #{adapter_name}, which holds no eras"

        # The settings its journal store is connected with: the world's, and `HECKS_SCHEMA` for a
        # domain on a shared database, whose schema production takes from the environment.
        #
        # @return [Hash] the settings
        def settings
          declared = registry.binding_settings(bluebook.name, Ports::Persistence::VERB, adapter_name)
          ENV["HECKS_SCHEMA"] ? declared.merge(schema: ENV["HECKS_SCHEMA"]) : declared
        end

        # The text the era is frozen from: the bluebook source as it stands on disk.
        #
        # @return [String] the text
        # @raise [Runtime::NotFound] if no file declares the bluebook
        def source_text
          Runtime::EraCheck.source_text_for(bluebook, directory) or
            raise Runtime::NotFound, "no file under #{directory} declares #{bluebook.name}"
        end

        # An era with the name it would be minted under, worked out in memory when none was stored.
        # Naming an era is a write, so a read never does it.
        #
        # @param era [Hash] an era as `Lineage#eras` answers it
        # @return [Hash] the era, with `hash` and `label` filled in
        def named(era)
          return era if era[:hash]

          hash = Runtime::StorageShape.mint_hash(PostgresEra::LineageManager.shadow(era[:held_text]))
          era.merge(hash: hash, label: hash[0, Runtime::StorageShape::LABEL_LENGTH])
        end

        # The bluebook's storage shape as it stands.
        #
        # @return [Hash] the projection `StorageShape.project` answers
        def shape = Runtime::StorageShape.project(bluebook)

        # Connects to the journal store and yields a lineage over it. Nothing is provisioned, so a
        # database that holds no eras is left as it is.
        #
        # @yield [Lineage] the domain's lineage
        # @return [Object] the block's value
        def reading
          db = PostgresEra.connect_for(bluebook.name, settings)
          yield PostgresEra::Lineage.new(db, bluebook.name)
        ensure
          db&.close
        end

        # Connects to the journal store, refuses a role that bypasses the write fence unless the
        # world allows it, provisions the lineage tables, and yields a lineage over it.
        #
        # @yield [Lineage] the domain's lineage
        # @return [Object] the block's value
        # @raise [Runtime::WiringError] on a superuser connection the world has not allowed
        def writing
          db = PostgresEra.connect_for(bluebook.name, settings)
          lineage = PostgresEra::Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as)
          lineage.check_fence_applies!(allow_superuser: PostgresEra.setting(settings, :allow_superuser, default: false))
          lineage.ensure_base!
          yield lineage
        ensure
          db&.close
        end

        # The eras a lineage holds, without provisioning anything: none when the lineage tables do
        # not exist yet.
        #
        # @param lineage [Lineage] the domain's lineage
        # @return [Array<Hash>] `Lineage#eras`, verified against their digests; empty when none held
        def held_eras(lineage)
          present = lineage.db.exec("SELECT to_regclass('hecks_eras') AS present")[0]["present"]
          present ? lineage.eras : []
        end
      end
    end
  end
end
