module Hecks
  module Projections
    module Deploy
      module Scripts
        # The `deployed_to("AwsFargate")` settings the hosting scripts read,
        # with their defaults and the check each value must pass.
        #
        # Every value ends up inside a shell script or a Makefile, so each one
        # is refused unless it matches a conservative pattern for what it names
        # (a region, an ECR repository, a CloudFormation parameter). That check
        # is what lets the renderers write values without per-context escaping.
        #
        # The keys are documented on `Scripts`.
        class Settings
          CONTAINER = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
          RESOURCE  = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
          REPOSITORY = %r{\A[a-z0-9][a-z0-9._/-]*\z}
          PARAMETER = /\A[A-Za-z0-9]+\z/
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

          # Reads and checks every hosting setting.
          #
          # @param deploy_settings [Hash{Symbol => Object}] the world's
          #   `deployed_to("AwsFargate")` settings
          # @param infra_name [String] the domain's AWS-facing name, which the generated
          #   template gives its container and ECR repository
          # @param stack_name [String] the CloudFormation stack, which the generated
          #   template also gives its cluster and service
          # @param region [String] the validated AWS region
          # @raise [ArgumentError] if `hecks_release` is missing, or a value
          #   does not match the pattern for what it names
          def initialize(deploy_settings:, infra_name:, stack_name:, region:)
            @raw = deploy_settings
            @infra_name = infra_name
            @region = check(:region, region, REGION)
            @stack = check(:stack_name, stack_name, RESOURCE)
            @cluster = check(:ecs_cluster, fetch(:ecs_cluster, stack_name), RESOURCE)
            @service = check(:ecs_service, fetch(:ecs_service, stack_name), RESOURCE)
            @containers = list(:containers, [infra_name]).each { |name| check(:containers, name, CONTAINER) }
            @hecks_release = read_release
            @hecks_source = check(:hecks_source, fetch(:hecks_source, DEFAULT_SOURCE), SOURCE)
            @hecks_cache_dir = check(:hecks_cache_dir, fetch(:hecks_cache_dir, DEFAULT_CACHE_DIR), MAKE_PATH)
            read_smoke
            @expected_eras = list(:expected_eras, []).each { |era| check(:expected_eras, era, ERA) }
            @public_url = optional(:public_url, %r{\Ahttps?://[^\s'"$`\\]+\z})
          end

          # Names the ECR repository a container's image is pushed to.
          #
          # @param container [String] one of `containers`
          # @return [String] the `ecr_repositories` override, else the infra name for a single
          #   container, else `<infra name>-<container>`
          def repository_for(container)
            override = mapping(:ecr_repositories)[container]
            return check(:ecr_repositories, override, REPOSITORY) if override

            single? ? @infra_name : "#{@infra_name}-#{container}"
          end

          # Names the CloudFormation parameter that holds a container's image tag.
          #
          # @param container [String] one of `containers`
          # @return [String] the `image_tag_parameters` override, else `ImageTag` for a single
          #   container, else `<Container>ImageTag`
          def image_tag_parameter_for(container)
            override = mapping(:image_tag_parameters)[container]
            return check(:image_tag_parameters, override, PARAMETER) if override

            single? ? "ImageTag" : "#{container.split(/[_-]/).map(&:capitalize).join}ImageTag"
          end

          # Tells whether the stack runs one container.
          #
          # @return [Boolean] true when `containers` names exactly one
          def single? = containers.size == 1

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

          def mapping(key)
            fetch(key, {}).to_h { |name, value| [name.to_s, value.to_s] }
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
