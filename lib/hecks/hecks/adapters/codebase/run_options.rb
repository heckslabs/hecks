# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      # What a spec run's arguments become: the variables the specs read.
      # A person names them in a request, so they never set them in a shell.
      module RunOptions
        module_function

        # The variables the specs read, set for one example only.
        #
        # @param args [Hash] `strict`, `seeds`, `environment` and `declaration_cache`, each
        #   perhaps absent
        # @return [Hash{String => String}] only those the run named
        def spec_env(args)
          { "CI" => ("true" if args[:strict] == true), "PROPERTY_SEEDS" => args[:seeds]&.to_s,
            "HECKS_ENVIRONMENT" => args[:environment],
            "HECKS_NO_DECLARATION_CACHE" => ("1" if args[:declaration_cache] == false) }.compact
        end
      end
    end
  end
end
