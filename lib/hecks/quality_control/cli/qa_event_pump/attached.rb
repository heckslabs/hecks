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

        # @return [Array<Hecks::Registry>] the registries of every domain booted so far this run
        def registries = @runtimes.values.map(&:registry)

        # @param name [String] an attached domain name
        # @return [String] the directory that boots it
        def dir(name) = @dirs.fetch(name)

        # @param name [String] an attached domain name
        # @return [Hecks::Runtime::Dispatcher] the domain booted once, and kept for the run
        def runtime(name)
          @runtimes[name] ||= Hecks.boot(dir(name))
        end

        # Whether a domain booted in this process has already delivered `policy` for `event`. The
        # reaction log keeps the event id each reaction answered, so a second run of the same event
        # in this process is skipped whatever the cursor says.
        #
        # @param event [Hecks::Runtime::Event] the event, with its id
        # @param policy [Hecks::Bluebook::Policy] the policy about to run
        # @return [Boolean] true when a delivered reaction for this event and policy is logged
        def reacted?(event, policy)
          registries.any? do |registry|
            registry.reaction_log.any? do |record|
              record[:delivered] && record[:policy] == policy.name && record[:on] == event.name &&
                registry.reaction_event(record) == event.id
            end
          end
        end

        private

        def default_dirs(root, env)
          {
            "QualityControl" => env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook")),
            "Fixer"          => File.join(root, "lib/hecks/fixer"),
            "Coder"          => File.join(root, "lib/hecks/coder"),
            "CiPipeline"     => File.join(root, "lib/hecks/ci_pipeline")
          }
        end
      end
    end
  end
end
