# frozen_string_literal: true

require_relative "../console_capture"

module Hecks
  module Adapters
    class MainIntegration
      # How a launchd job of the domain is scheduled, from the Hecks world's
      # `launchd_job "Beat", process_type: "Standard", nice: 10` setting. Standard QoS lets macOS
      # run the job, and every process it starts, on the performance cores; Background pins them
      # to the efficiency cores, so a world that declares it is refused by name.
      class JobPriority
        # The world verb that carries the setting.
        VERB = "launchd_job"

        # What holds when the world declares nothing; the world's own line says the same.
        DEFAULTS = { process_type: "Standard", nice: 10, low_priority_io: false }.freeze

        # @param registry [Runtime::Registry, nil] the booted registry whose Hecks world is read
        # @param verb [String] the world verb that declares the job (`launchd_job`: the beat)
        # @param fallback [Hash] what holds for this job beyond what the world declares
        # @return [JobPriority] the declared priority, else the fallback and the defaults
        def self.from(registry, verb: VERB, **fallback)
          declared = registry&.world("Hecks")&.for_verb(verb) || {}
          new(**fallback, **declared.slice(*DEFAULTS.keys))
        end

        # @param process_type [String] launchd's ProcessType; never Background
        # @param nice [Integer] the nice increment
        # @param low_priority_io [Boolean] whether launchd throttles the job's disk IO
        # @raise [ConsoleCapture::Failure] when the process type is Background
        def initialize(**declared)
          @held = DEFAULTS.merge(declared)
          return unless @held[:process_type].to_s == "Background"

          raise ConsoleCapture::Failure, "launchd_job process_type Background runs only on the efficiency cores"
        end

        # @return [Hash{Symbol => Object}] the process type, nice and low-priority IO flag
        def to_h = @held

        # @return [String] the property list keys that schedule the job
        def keys
          lines = ["<key>ProcessType</key>\n  <string>#{@held[:process_type]}</string>"]
          lines << "<key>LowPriorityIO</key>\n  <true/>" if @held[:low_priority_io]
          lines << "<key>Nice</key>\n  <integer>#{Integer(@held[:nice])}</integer>"
          lines.join("\n  ")
        end
      end
    end
  end
end
