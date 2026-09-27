module Hecks
  module Projections
    module Deploy
      module Scripts
        # The `deployed_to("AwsFargate")` settings the hosting scripts read, checked
        # against a conservative pattern so a renderer can splice one in without escaping.
        class Settings
          RESOURCE  = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
          REGION    = /\A[a-z]{2}(-[a-z]+)+-\d\z/
          GITHUB_REPO = %r{\A[\w.-]+/[\w.-]+\z}
          WORKFLOW  = /\A[\w.-]+\.ya?ml\z/
          REF       = %r{\A[\w./-]+\z}
          ERA       = /\A[0-9a-zA-Z._-]+\z/
          RELEASE   = /\Av?\d+\.\d+\.\d+([.-][0-9A-Za-z.-]+)?\z/
          SOURCE    = %r{\A[\w.@:/~-]+\z}
          MAKE_PATH = /\A[^\s#]+\z/

          DEFAULT_SOURCE = "https://github.com/heckslabs/hecks.git".freeze
          DEFAULT_CACHE_DIR = "$(HOME)/.cache/hecks".freeze

          attr_reader :region, :stack, :cluster, :service, :containers, :hecks_release, :hecks_source,
                      :hecks_cache_dir, :smoke_repo, :smoke_workflow, :smoke_ref, :expected_eras, :public_url

          # `plan.layout` holds the containers; `plan.names` the cluster and service.
          def initialize(deploy_settings:, plan:, stack_name:, region:)
            @raw = deploy_settings
            @region = check(:region, region, REGION)
            @stack = check(:stack_name, stack_name, RESOURCE)
            @cluster = check(:ecs_cluster, fetch(:ecs_cluster, plan.names.fetch(:cluster)), RESOURCE)
            @service = check(:ecs_service, fetch(:ecs_service, plan.names.fetch(:service)), RESOURCE)
            @containers = plan.layout.all
            @hecks_release = read_release
            @hecks_source = check(:hecks_source, fetch(:hecks_source, DEFAULT_SOURCE), SOURCE)
            @hecks_cache_dir = check(:hecks_cache_dir, fetch(:hecks_cache_dir, DEFAULT_CACHE_DIR), MAKE_PATH)
            read_smoke
            @expected_eras = list(:expected_eras, []).each { |era| check(:expected_eras, era, ERA) }
            @public_url = optional(:public_url, %r{\Ahttps?://[^\s'"$`\\]+\z})
          end

          private

          def read_release
            release = fetch(:hecks_release, nil)
            raise ArgumentError, missing_release_message unless release

            check(:hecks_release, release.to_s, RELEASE).delete_prefix("v")
          end

          def read_smoke
            @smoke_repo = optional(:smoke_repo, GITHUB_REPO)
            @smoke_workflow = optional(:smoke_workflow, WORKFLOW)
            @smoke_ref = check(:smoke_ref, fetch(:smoke_ref, "main"), REF)
          end

          def missing_release_message
            <<~MSG
              deployed_to("AwsFargate") enables hosting_scripts but names no hecks_release. Pin one, e.g.:

                  deployed_to("AwsFargate") do
                    ...
                    hosting_scripts true
                    hecks_release "2.5.1"
                  end

              so the domain image is built from a fixed Hecks release, not from a checkout on one machine.
            MSG
          end

          def fetch(key, default)
            @raw.key?(key) ? @raw[key] : default
          end

          def optional(key, pattern)
            value = fetch(key, nil)
            value.nil? ? nil : check(key, value.to_s, pattern)
          end

          def list(key, default)
            Array(fetch(key, default)).map(&:to_s)
          end

          def check(key, value, pattern)
            return value if value.is_a?(String) && value.match?(pattern)

            raise ArgumentError,
                  "deployed_to(\"AwsFargate\") #{key} #{value.inspect} is not a valid value (expected #{pattern.inspect})"
          end
        end
      end
    end
  end
end
