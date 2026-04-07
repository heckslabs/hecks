
module Hecks
  class Configuration
    # Hecks::Configuration::SqlSetup
    #
    # Generates and evals SQL adapter classes for each aggregate at boot time.
    # These adapters wrap Sequel datasets and implement the repository port.
    # Mixed into Configuration to provide SQL persistence setup during Hecks.configure.
    #
    module SqlSetup
      include HecksTemplating::NamingHelpers
      private

      # Generates SQL adapter (repository) classes for each aggregate in the domain.
      #
      # Uses SqlAdapterGenerator to produce Ruby source code for each aggregate's
      # SQL repository, then evals it into the runtime. The generated classes
      # are namespaced under {DomainModule}::Adapters::{AggregateName}SqlRepository.
      #
      # @param domain_obj [DomainModel::Structure::Domain] the domain containing
      #   aggregates to generate adapters for
      # @return [void]
      def generate_adapters(domain_obj)
        domain_obj.aggregates.each do |agg|
          gen = Generators::SQL::SqlAdapterGenerator.new(
            agg, domain_module: domain_module_name(domain_obj.name)
          )
          eval(gen.generate, TOPLEVEL_BINDING, "(hecks:sql:#{agg.name})")
        end
      end
    end
  end
end
