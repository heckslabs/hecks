# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaEventPump
      # The domains the pump reads and reacts for: each name with the directory that boots it. The
      # ledger, `QualityControl`, is the one whose `EventCursor` rows hold the positions.
      class Attached
        # @param root [String] the repository root the default directories are found under
        # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` overrides the ledger's directory
        # @param dirs [Hash{String => String}, nil] the directories by domain name, in place of the
        #   defaults
        def initialize(root:, env: ENV, dirs: nil)
          @dirs = dirs || default_dirs(root, env)
          @runtimes = {}
        end

        # @return [Array<String>] the attached domain names, in the order the pump visits them
        def names = @dirs.keys

        # @param name [String] a domain name
        # @return [Boolean] whether the pump attaches this domain
        def known?(name) = @dirs.key?(name)

        # @param name [String] an attached domain name
        # @return [String] the directory that boots it
        def dir(name) = @dirs.fetch(name)

        # @param name [String] an attached domain name
        # @return [Hecks::Runtime::Dispatcher] the domain booted once, and kept for the run
        def runtime(name)
          @runtimes[name] ||= Hecks.boot(dir(name))
        end

        private

        def default_dirs(root, env)
          {
            "QualityControl" => env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook")),
            "Fixer"          => File.join(root, "lib/hecks/fixer"),
            "CiPipeline"     => File.join(root, "lib/hecks/ci_pipeline")
          }
        end
      end
    end
  end
end
