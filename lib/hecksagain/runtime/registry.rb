module Hecksagain
  module Runtime
    class WiringError < StandardError; end

    class Registry
      attr_reader :root, :bluebooks, :hecksagons, :ports, :adapters, :worlds, :event_log,
                  :reaction_log, :saga_log, :saga_instances

      def initialize(root: nil)
        @root         = root
        @bluebooks    = {}
        @hecksagons   = {}
        @ports     = {}
        @adapters     = {}
        @worlds       = {}
        @event_log    = []
        @reaction_log = []
        @saga_log = []
        @saga_instances = Hash.new { |h, k| h[k] = {} }
        @repositories = {}
        @projection_repositories = {}
      end

      def add_bluebook(item)  = @bluebooks[item.name]  = item
      def add_hecksagon(item) = @hecksagons[item.domain] = item
      def add_port(item)    = @ports[item.name]   = item
      def add_adapter(item)   = @adapters[item.name]   = item
      def add_world(item)     = @worlds[item.domain]   = item

      def bluebook(name)  = @bluebooks[name.to_s]
      def hecksagon(name) = @hecksagons[name.to_s]
      def world(name)     = @worlds[name.to_s]

      def verbs = @bluebooks.values.flat_map(&:verbs).sort

      def repository(domain, aggregate)
        @repositories[[domain.to_s, aggregate.name]] ||= Ports::Persistence.repository(self, domain, aggregate)
      end

      def read_repository(domain, aggregate)
        key = [domain.to_s, aggregate.name]
        binding = Ports::Projection.binds_for(self, domain, aggregate).first
        return repository(domain, aggregate) unless binding

        projection = (@projection_repositories[key] ||= begin
          projection = Ports::Persistence::RepositoryFactory.build(self, domain, aggregate, binding,
                                                                    recover: true, settings_verb: Ports::Projection::VERB)
          projection
        end)
        authoritative = repository(domain, aggregate)
        projection_current?(projection, authoritative) ? projection : authoritative
      end

      def projection_current?(projection, authoritative)
        projected_entries = projection.entries
        source_entries = authoritative.entries
        return false unless projected_entries.length == source_entries.length
        return false unless projected_entries.zip(source_entries).all? do |projected, source|
          projected.operation == source.operation && projected.id == source.id && projected.state == source.state
        end

        projected_rows = projection.all.map(&:to_h).sort_by { |row| row.fetch(:id).to_s }
        source_rows = authoritative.all.map(&:to_h).sort_by { |row| row.fetch(:id).to_s }
        projected_rows == source_rows
      rescue StandardError
        false
      end

      def verify!
        verify_default_adapter!

        @hecksagons.each_value do |hexagon|
          hexagon.binds.each do |bind|
            aggregate = bluebook(hexagon.domain)&.aggregate(bind.aggregate_name)
            raise WiringError, "#{bind.aggregate} is bound but not declared in the bluebook" unless aggregate

            check_verb(bind)

            repository(hexagon.domain, aggregate)
          end
        end
        self
      end

      def verify_default_adapter!
        name = Ports::Persistence::DEFAULT_ADAPTER

        check_verb(
          Bluebook::IR::Bind.new(
            aggregate: "(default)",
            verb:      Ports::Persistence::VERB,
            adapter:   name
          )
        )
        adapter_class(name)
        self
      rescue WiringError => error
        raise WiringError,
              "the default persistence adapter (#{name}) is not usable, so an " \
              "aggregate with no bind could not be given one: #{error.message}"
      end

      def check_verb(bind)
        port = port_for(bind)
        return if port.verb.to_s == bind.verb.to_s

        raise WiringError,
              "#{bind.adapter} implements the #{port.name} port (verb #{port.verb}) " \
              "and cannot satisfy #{bind.verb}"
      end


      def check_settings(bind, settings)
        adapter = @adapters[bind.adapter]
        return unless adapter

        declared = settings.keys - [:adapter]
        unknown  = declared.reject { |field| adapter.declares?(field) }
        return if unknown.empty?

        raise WiringError,
              "#{bind.adapter} does not declare #{unknown.map(&:inspect).join(', ')} — " \
              "it declares #{adapter.all_fields.map(&:inspect).join(', ')}. " \
              "Add the field to the adapter, or remove it from the world."
      end

      def port_for(bind)
        adapter = @adapters[bind.adapter]
        raise WiringError, "unknown adapter #{bind.adapter.inspect}" unless adapter

        @ports[adapter.port] ||
          raise(WiringError, "adapter #{bind.adapter} declares unknown port #{adapter.port.inspect}")
      end

      def adapter_class(name)
        Adapters.const_get(name)
      rescue NameError
        raise WiringError, "no Ruby adapter implementation for #{name.inspect} " \
                           "(expected Hecksagain::Adapters::#{name})"
      end
    end
  end
end
