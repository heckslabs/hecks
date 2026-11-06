# frozen_string_literal: true

require "hecks"
require "hecks/ports/persistence/plugins/era"
require "hecks/indifferent_key"
require_relative "held_domain/renaming"

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
        include Renaming

        MODES = %i[translated bare scaffold].freeze

        attr_reader :registry, :bluebook, :directory, :adapter_name

        # @return [String] the held domain's name
        def domain_name = bluebook.name

        # @return [Array<String>] the names of every bluebook the registry loaded
        def bluebook_names = registry.bluebooks.keys

        # @return [Array<Bluebook::Aggregate>] the held domain's aggregates
        def aggregates = bluebook.aggregates

        # @return [Array<Bluebook::Translation>] the translation edges the domain loaded
        def translations = registry.translations

        # Loads a domain and finds where its eras would be held.
        #
        # @param path [String] the domain directory, or the project holding its `bluebook/`
        # @param mode [Symbol] one of `MODES`
        # @param environment [String, nil] the overlay under `environments/` to load last;
        #   `HECKS_PROJECT_ENVIRONMENT` when not given
        # @return [HeldDomain] the loaded domain
        # @raise [Runtime::NotFound] if the directory does not exist, declares no bluebook, or
        #   does not load
        def self.open(path, mode: :translated, environment: ENV.fetch("HECKS_PROJECT_ENVIRONMENT", nil))
          raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

          loading = Ports::Loading.bootstrap
          directory = loading.bluebook_directory(path)
          registry = Runtime::Registry.new(root: File.dirname(directory))
          load_into(registry, loading, directory, mode, environment)
          new(registry, directory)
        rescue Errno::ENOENT
          raise Runtime::NotFound, "no such domain #{path.inspect}"
        rescue Bluebook::DSL::Malformed => e
          raise Runtime::NotFound, "REFUSED at load: #{e.message}"
        end

        # @api private
        def self.load_into(registry, loading, directory, mode, environment)
          Hecks.with_registry(registry) do
            loading.load_library
            loading.load_project(loading.shared_root(nil, directory))
            case mode
            when :translated then loading.load_domain(directory, environment: environment)
            when :bare then load_bare(loading, directory, environment)
            else load_scaffold(loading, directory, environment)
            end
          end
        end

        # @api private
        def self.load_scaffold(loading, directory, environment)
          loading.load_each(directory, %w[*.port *.adapter])
          loading.load_bluebooks(directory)
          loading.load_each(directory, %w[*.hecksagon *.world])
          loading.load_overlay(directory, environment)
        end

        # @api private
        def self.load_bare(loading, directory, environment)
          loading.load_each(directory, %w[*.port *.adapter *.bluebook *.hecksagon *.world])
          loading.load_overlay(directory, environment)
        end

        # @param registry [Runtime::Registry] the loaded registry
        # @param directory [String] the domain's bluebook directory
        # @param name [String, nil] the bluebook to hold, by name; the registry's first when absent
        # @raise [Runtime::NotFound] if the registry holds no bluebook, or a bluebook no aggregate
        def initialize(registry, directory, name = nil)
          @registry = registry
          @directory = directory
          @bluebook = name ? registry.bluebooks[name] : registry.first_bluebook

          raise Runtime::NotFound, "no bluebook in #{directory}" unless @bluebook

          first = @bluebook.aggregates.first or raise Runtime::NotFound, "#{@bluebook.name} declares no aggregates"
          @adapter_name = Ports::Persistence::BindingPolicy.resolve(registry, @bluebook.name, first).adapter
        end

        # Whether the bound store keeps eras, as `RevisionCheck` answers it.
        def capable? = Runtime::RevisionCheck.lineage_capable_for?(registry, bluebook.name, adapter_name)

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
          declared = declared.merge(schema: ENV["HECKS_SCHEMA"]) if ENV["HECKS_SCHEMA"]
          declared = declared.merge(schema: @schema) if @schema
          @database ? declared.merge(database: @database) : declared
        end

        # The app role the world names, which provisioning grants what the app needs to write.
        #
        # @return [String, nil] the role, or nil when the world names none
        def app_role = IndifferentKey.read(settings, :role)

        # Names the schema its journal store is read in, over the world's and `HECKS_SCHEMA`, so a
        # rehearsal reads the schema it reports.
        #
        # @param schema [String] a schema name
        # @return [HeldDomain] self
        def read_schema(schema)
          @schema = schema
          self
        end

        # Points the journal store at another database than its world names, so a rehearsal
        # reads a copy and never the world's own. Every read and write after this reaches it.
        #
        # @param database [String] a `postgres://` URL
        # @return [HeldDomain] self
        def read_from(database)
          @database = database
          self
        end

        # The text the era is frozen from: the bluebook source as it stands on disk.
        #
        # @return [String] the text
        # @raise [Runtime::NotFound] if no file declares the bluebook
        def source_text
          Runtime::RevisionCheck.source_text_for(bluebook, directory) or
            raise Runtime::NotFound, "no file under #{directory} declares #{bluebook.name}"
        end

        # An era with the name it would be minted under, worked out in memory when none was stored.
        # Naming an era is a write, so a read never does it.
        #
        # @param era [Hash] an era as `Lineage#eras` answers it
        # @return [Hash] the era, with `hash` and `label` filled in
        def named(era)
          return era if era[:hash]

          hash = PostgresRevision::LineageManager.held_hash(era)
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
          db = PostgresRevision.connect_for(bluebook.name, settings, provision: false)
          yield PostgresRevision::Lineage.new(db, bluebook.name, reading: true)
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
          db = PostgresRevision.connect_for(bluebook.name, settings)
          lineage = PostgresRevision::Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as)
          lineage.check_fence_applies!(allow_superuser: PostgresRevision.setting(settings, :allow_superuser, default: false))
          lineage.ensure_base!
          yield lineage
        ensure
          db&.close
        end

        # What a boot of the held bluebook would resolve, read from its database over a connection
        # that only reads: the resolution the boot records (`LineageManager::RevisionResolution`).
        #
        # @return [PostgresRevision::LineageManager::RevisionResolution::Answer]
        # @raise [Runtime::WiringError] if the connection is refused or a held text was altered
        def resolution
          PostgresRevision::LineageManager::RevisionResolution.read(bluebook: bluebook, settings: settings,
                                                                    translations: translations, directory: directory)
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
