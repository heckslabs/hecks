# = Hecks::Boot::MongoBoot
#
# Handles MongoDB adapter lifecycle: connects to a MongoDB instance,
# generates repository adapter classes for each aggregate, and returns
# adapter instances keyed by aggregate name.
#
#   adapters = MongoBoot.setup(domain, client)
#   # => { "Pizza" => #<PizzasDomain::Adapters::PizzaMongoRepository>, ... }
#
module Hecks
  module Boot
    module MongoBoot
      extend HecksTemplating::NamingHelpers

      module_function

      # Connects to MongoDB using the mongo Ruby driver.
      #
      # @param config [Hash] connection config with :uri or defaults
      # @return [Mongo::Client] the MongoDB client
      def connect(config)
        require_mongo!
        uri = config[:uri] || "mongodb://localhost:27017"
        db_name = config[:database] || "hecks"
        Mongo::Client.new(uri, database: db_name)
      end

      # Performs full MongoDB setup: generates adapter classes and returns
      # instantiated repository objects.
      #
      # @param domain [DomainModel::Structure::Domain] the domain model
      # @param client [Mongo::Client] the MongoDB client
      # @return [Hash<String, Object>] adapter instances keyed by aggregate name
      def setup(domain, client)
        mod_name = domain_module_name(domain.name)
        generate_adapters(domain, mod_name)
        instantiate_adapters(domain, client, mod_name)
      end

      # Generates and evals MongoDB repository classes for each aggregate.
      def generate_adapters(domain, mod_name)
        domain.aggregates.each do |agg|
          gen = MongoAdapterGenerator.new(agg, domain_module: mod_name)
          eval(gen.generate, TOPLEVEL_BINDING, "(mongo_adapter:#{agg.name})", 1)
        end
      end

      # Instantiates MongoDB repository objects for all aggregates.
      def instantiate_adapters(domain, client, mod_name)
        mod = Object.const_get(mod_name)
        adapters = {}
        domain.aggregates.each do |agg|
          safe_name = domain_constant_name(agg.name)
          collection_name = domain_aggregate_slug(agg.name)
          collection = client[collection_name]
          repo_class = mod::Adapters.const_get("#{safe_name}MongoRepository")
          adapters[agg.name] = repo_class.new(collection)
        end
        adapters
      end

      # Requires the mongo gem, raising a helpful error if missing.
      def require_mongo!
        require "mongo"
      rescue LoadError
        raise LoadError,
          "The mongo gem is required for MongoDB adapters. " \
          "Add gem \"mongo\" to your Gemfile."
      end
    end
  end
end
