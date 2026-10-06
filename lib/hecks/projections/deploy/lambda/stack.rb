require_relative "../text_template"
require_relative "../shared"
require_relative "stack/reading"
require_relative "stack/reading_web"
require_relative "stack/checks"
require_relative "stack/readers"
require_relative "stack/blocks"
require_relative "stack/web"
require_relative "stack/recipes"
require_relative "stack/deploy_chain"

module Hecks
  module Projections
    module Deploy
      module Lambda
        # Everything the Lambda generator knows about one stack, read and checked once from the
        # world: the target's declared sizes, whether a field is marked pii, the owner a Shared
        # database borrows, the web function. The templates under `templates/lambda/` read each
        # marker's value from the method of the same name.
        class Stack
          include Reading
          include ReadingWeb
          include Checks
          include Readers
          include Blocks
          include Web
          include Recipes
          include DeployChain

          attr_reader :domain, :root, :world_file, :domain_name, :declared_domain_name, :deploy_settings, :infra_name,
                      :db_name, :region, :memory, :timeout, :aurora, :shared, :rust_web, :dispatch_none,
                      :webhook_secret_env, :webhook_handler_module, :cross_domain_targets, :pii_detected,
                      :geo_restriction_type, :geo_restriction_countries, :owner_domain_name, :owner_stack_name,
                      :owner_db_name, :hecks_schema, :logical_id, :stack_prefix, :stack_name, :web_handler_present,
                      :pg_version, :web_logical_id, :web_code_uri, :web_handler_relpath, :google_oauth_present

          # @param options [Hash] the generation options `Lambda.call` receives
          # @raise [ArgumentError] if the domain's deploy settings are invalid or conflict
          def initialize(options)
            read_options(options)
            detect_pii
            read_names
            declare_target
            check_pii_region
            read_owner
            derive_ids
            read_web
            check_web
          end
        end
      end
    end
  end
end
