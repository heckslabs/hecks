require_relative "../scripts/settings"

module Hecks
  module Projections
    module Deploy
      module Box
        # The hosting words of a `deployed_to("AwsBox")` block: `hosting_scripts true` and the
        # settings the generated `deploy-service.sh`, `smoke-after-deploy.sh` and `expected-era`
        # read. Every value is matched against a conservative pattern before a script splices it in.
        module HostingSettings
          PARAMETER = /\A[A-Za-z][A-Za-z0-9]{0,254}\z/
          STACK     = /\A[a-zA-Z][a-zA-Z0-9-]{0,127}\z/
          PUBLIC_URL = %r{\Ahttps?://[^\s'"$`\\]+\z}
          # The words that only mean something to the hosting scripts.
          WORDS = %i[hosting_stack smoke_repo smoke_workflow smoke_ref expected_eras public_url].freeze

          # The checked hosting settings.
          #
          # @!attribute [r] stack [String, nil] the CloudFormation stack whose image-tag parameters
          #   feed the task definition; nil without a `task_definition`
          # @!attribute [r] smoke_repo [String, nil] the GitHub repository holding the workflow
          # @!attribute [r] smoke_workflow [String] the smoke workflow's file name
          # @!attribute [r] smoke_ref [String] the ref the smoke workflow is dispatched on
          # @!attribute [r] expected_eras [Array<String>] the eras `expected-era` lists
          # @!attribute [r] public_url [String, nil] the live site, for `make check-era`
          Hosting = Struct.new(:stack, :smoke_repo, :smoke_workflow, :smoke_ref, :expected_eras,
                               :public_url, keyword_init: true)

          module_function

          # @param settings [Hash{Symbol => Object}] the world's `AwsBox` settings
          # @param task_definition [String, nil] the declared task definition family
          # @return [Hosting, nil] the checked settings, or nil when the world has not opted in
          # @raise [ArgumentError] when a hosting word is invalid, missing or has nothing to act on
          def read(settings, task_definition)
            flag = settings.fetch(:hosting_scripts, false)
            raise ArgumentError, "hosting_scripts: #{flag.inspect} must be true or false" unless [true, false].include?(flag)

            unless flag
              stray = WORDS.select { |word| settings.key?(word) }
              raise ArgumentError, "#{stray.join(', ')} only apply with hosting_scripts true" unless stray.empty?

              return nil
            end

            Hosting.new(stack: read_stack(settings, task_definition), **read_smoke(settings),
                        expected_eras: eras(settings), public_url: optional(settings, :public_url, PUBLIC_URL))
          end

          # With a task definition, the stack that registers its revisions is where a new image tag
          # goes, so it has to be named. Without one the box is rolled from `services.json` and no
          # stack holds a tag.
          def read_stack(settings, task_definition)
            stack = settings[:hosting_stack]
            if task_definition.nil?
              raise ArgumentError, "hosting_stack names the stack behind a task_definition; this world has none" if stack

              return nil
            end
            raise ArgumentError, missing_stack(task_definition) if stack.nil?

            check(:hosting_stack, stack, STACK)
          end

          def read_smoke(settings)
            workflow = settings[:smoke_workflow]
            raise ArgumentError, missing_workflow if workflow.nil?

            {
              smoke_workflow: check(:smoke_workflow, workflow, Scripts::Settings::WORKFLOW),
              smoke_repo:     optional(settings, :smoke_repo, Scripts::Settings::GITHUB_REPO),
              smoke_ref:      check(:smoke_ref, settings.fetch(:smoke_ref, "main"), Scripts::Settings::REF)
            }
          end

          def eras(settings)
            Array(settings.fetch(:expected_eras, [])).map { |era| check(:expected_eras, era.to_s, Scripts::Settings::ERA) }
          end

          def optional(settings, key, pattern)
            value = settings[key]
            value.nil? ? nil : check(key, value, pattern)
          end

          def check(key, value, pattern)
            return value if value.is_a?(String) && value.match?(pattern)

            raise ArgumentError, "#{key}: #{value.inspect} does not match #{pattern.inspect}"
          end

          def missing_workflow
            <<~MSG
              deployed_to("AwsBox") enables hosting_scripts but names no smoke_workflow. Name the GitHub
              workflow file the post-deploy smoke dispatches, e.g.:

                  deployed_to("AwsBox") do
                    ...
                    hosting_scripts true
                    smoke_workflow "smoke-prod.yml"
                  end

              A deploy that ends without a smoke of the live site cannot tell a roll that took from one
              that only looked live.
            MSG
          end

          def missing_stack(family)
            <<~MSG
              deployed_to("AwsBox") enables hosting_scripts with task_definition #{family.inspect} but names no
              hosting_stack. Name the CloudFormation stack whose TaskDefinition resource reads an image-tag
              parameter per container (`<Name>ImageTag` unless a container sets `tag_parameter`), e.g.:

                  hosting_stack "my-platform"

              deploy-service.sh sets that parameter to the tag it pushed, so the stack, not a hand-registered
              revision, is the source of truth for what runs.
            MSG
          end
        end
      end
    end
  end
end
