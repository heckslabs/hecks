# frozen_string_literal: true

require_relative "../sqlite_status/read_only"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # The databases a registry's aggregates are persisted in, each with how it is read. An
          # aggregate bound to Memory (or to an adapter with no event log) yields a store that is
          # named but cannot be opened, so the trace can say why it has nothing to show.
          class Stores
            SQLITE = %w[Sqlite SqlitePersistence].freeze
            POSTGRES = %w[Postgres].freeze

            # One place events are kept: `kind` is `:sqlite`, `:postgres` or `:none`.
            Store = Struct.new(:kind, :adapter, :key, :name, :settings)

            # @param registry [Runtime::Registry] a described registry
            # @param only [String, nil] keep only stores whose database contains this text
            # @return [Array<Store>] one per distinct database, in the order aggregates name them
            def self.of(registry, only: nil)
              found = new(registry).stores
              only.to_s.empty? ? found : found.select { |store| store.key.to_s.include?(only.to_s) }
            end

            def initialize(registry)
              @registry = registry
            end

            # @return [Array<Store>] the distinct stores
            def stores
              all = @registry.bluebooks.values.flat_map { |bluebook| bound(bluebook) }
              all.uniq(&:key)
            end

            private

            def bound(bluebook)
              bluebook.aggregates.filter_map { |aggregate| store_for(bluebook, aggregate) }
            rescue Runtime::WiringError
              []
            end

            def store_for(bluebook, aggregate)
              adapter = Ports::Persistence::BindingPolicy.resolve(@registry, bluebook.name, aggregate).adapter.to_s
              settings = settings_for(bluebook, aggregate, adapter)
              build(bluebook.name, adapter, settings)
            end

            def settings_for(bluebook, aggregate, adapter)
              declared = @registry.binding_settings(bluebook.name, Ports::Persistence::VERB, adapter)
              @registry.with_adapter_defaults(adapter, aggregate, declared).transform_keys(&:to_sym)
            end

            def build(name, adapter, settings)
              kind = kind_of(adapter)
              key = kind == :none ? adapter : location(kind, settings)
              Store.new(kind, adapter, key, name, settings)
            end

            def kind_of(adapter)
              return :sqlite if SQLITE.include?(adapter)

              POSTGRES.include?(adapter) ? :postgres : :none
            end

            def location(kind, settings)
              database = settings[:database].to_s
              return [database, settings[:schema]].compact.join("#") if kind == :postgres

              database.start_with?("/") ? database : File.join(@registry.root || Dir.pwd, database)
            end
          end
        end
      end
    end
  end
end
