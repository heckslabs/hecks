# frozen_string_literal: true

require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # How much of the spec suite this machine may run, from the world's
      # `test_scope "Local", suite_runs_in: "ci", spec_files_limit: n` setting. Owner decision: the
      # full suite runs only in CI (the `rspec` check is `runs_in: "ci"` in the Vocabulary rows),
      # and a change is checked locally by the quick gate and the specs named for it, at most
      # `spec_files_limit` files per call.
      #
      # CI is detected here, by the environment (`CI` or `GITHUB_ACTIONS`), never by the bluebook. A
      # world that declares no `test_scope` (a client's project) is not limited.
      class TestScope
        # The world verb that carries the setting.
        VERB = "test_scope"

        # The spec files a directory holds.
        SPEC_GLOB = "**/*_spec.rb"

        # @param registry [Runtime::Registry, nil] the booted registry whose Hecks world is read
        # @return [Hash{Symbol => Object}] the declared setting, empty when none is
        def self.setting(registry) = registry&.world("Hecks")&.for_verb(VERB) || {}

        # @param registry [Runtime::Registry, nil]
        # @return [Integer, nil] the most spec files a local call may run, nil when none is declared
        def self.limit(registry)
          declared = setting(registry)[:spec_files_limit]
          declared && Integer(declared)
        end

        # @param registry [Runtime::Registry, nil] the booted registry whose Hecks world is read
        # @param env [#[]] the process environment
        def initialize(registry, env: ENV)
          @setting = self.class.setting(registry)
          @env = env
        end

        # @return [Integer, nil] the limit that holds here: nil in CI or when none is declared
        def limit = (Integer(@setting[:spec_files_limit]) if @setting[:spec_files_limit] && !ci?)

        # @return [Boolean] whether this process runs in CI
        def ci? = %w[CI GITHUB_ACTIONS].any? { |name| !["", "false"].include?(@env[name].to_s) }

        # Lets a request through, or refuses one that would run more than this machine may. An
        # impacted run that names no cap gets the limit as its cap.
        #
        # @param operation [String] the `TestSuiteRun` operation
        # @param held [Hash] the record's fields, each perhaps a value object's `{ value: x }`
        # @param tree [Tree] the folder whose specs would run
        # @return [Hash] the fields to carry the operation out with
        # @raise [ConsoleCapture::Failure] naming the limit and CI
        def admit(operation, held, tree)
          args = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
          refuse!(operation, args, tree) unless ci?
          return held unless operation == "run_impacted_specs" && limit && args[:cap].nil?

          held.merge(cap: { value: limit })
        end

        private

        def refuse!(operation, args, tree)
          case operation
          when "run_suite" then refuse_suite
          when "run_spec_files" then refuse_files(files_in(args[:files], tree))
          when "run_impacted_specs" then refuse_cap(args[:cap])
          end
        end

        def refuse_suite
          return unless @setting[:suite_runs_in].to_s == "ci"

          fail!("the full suite runs in CI (rspec runs_in \"ci\"); run named specs, or run_impacted_specs!")
        end

        def refuse_files(count)
          return if limit.nil? || count <= limit

          fail!("run_spec_files! runs at most #{limit} spec files per call locally (spec_files_limit); #{count} named. " \
                "The full suite runs in CI (rspec runs_in \"ci\"): name fewer files, or run_impacted_specs!")
        end

        def refuse_cap(cap)
          return if limit.nil? || cap.nil? || Integer(cap) <= limit

          fail!("run_impacted_specs! caps at #{limit} spec files locally (spec_files_limit); cap.value=#{cap} is more. " \
                "The full suite runs in CI (rspec runs_in \"ci\")")
        end

        # A named directory counts as the spec files it holds.
        def files_in(files, tree)
          Array(files).flat_map { |name| name.to_s.split }.uniq.sum do |name|
            path = File.expand_path(name, tree.root)
            File.directory?(path) ? Dir.glob(File.join(path, SPEC_GLOB)).size : 1
          end
        end

        def fail!(message) = raise(ConsoleCapture::Failure, message)
      end
    end
  end
end
