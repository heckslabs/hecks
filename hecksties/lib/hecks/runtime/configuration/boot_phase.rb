# Hecks::Configuration::BootPhase
#
# Extracted boot logic from Configuration. Handles per-domain booting:
# loading the gem, creating Runtime, wiring SQL adapters, event sourcing,
# and ad-hoc queries.
#
module Hecks
  class Configuration
    # Hecks::Configuration::BootPhase
    #
    # Extracted boot logic handling per-domain booting: loading the gem, creating Runtime, wiring adapters.
    #
    module BootPhase
      include HecksTemplating::NamingHelpers

      private

      def boot_domain(d)
        domain_obj, domain_module = load_domain(d)
        store_domain_object(domain_obj)
        generate_adapters(domain_obj) if @adapter_type == :sql
        app = create_runtime(d, domain_obj, domain_module)
        app.capability(:crud)
        app.async(&@async_handler) if @async_handler
        @apps[d[:gem_name]] = app
        wire_event_sourcing(domain_obj, domain_module) if event_sourced?
        wire_ad_hoc_queries(domain_obj, domain_module, app) if @ad_hoc_queries
      end

      def store_domain_object(domain_obj)
        mod = domain_module_name(domain_obj.name)
        Hecks.domain_objects[mod] = domain_obj
      end

      def create_runtime(d, domain_obj, domain_module)
        adapter_type = @adapter_type
        db = @db
        bus = event_bus_for(d[:gem_name])

        Runtime.new(domain_obj, event_bus: bus) do
          if adapter_type == :sql
            domain_obj.aggregates.each do |agg|
              safe_name = domain_constant_name(agg.name)
              adapter_class = domain_module::Adapters.const_get("#{safe_name}SqlRepository")
              adapter agg.name, adapter_class.new(db)
            end
          end
        end
      end

      def wire_event_sourcing(domain_obj, domain_module)
        return unless @db
        recorder = Persistence::EventRecorder.new(@db)
        domain_obj.aggregates.each do |agg|
          agg_class = domain_module.const_get(domain_constant_name(agg.name))
          Persistence.bind_event_recorder(agg_class, recorder)
        end
      end

      def wire_ad_hoc_queries(domain_obj, domain_module, app)
        domain_obj.aggregates.each do |agg|
          agg_class = domain_module.const_get(domain_constant_name(agg.name))
          Querying::AdHocQueries.bind(agg_class, app[agg.name])
        end
      end

      def event_sourced?
        @adapter_options[:event_sourced] && @db
      end
    end
  end
end
