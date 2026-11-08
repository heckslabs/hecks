# frozen_string_literal: true

module Hecks
  module Adapters
    class FindingGithub
      # The switch on opening GitHub issues for run findings, read from the Tickets world's
      # `github_issues` setting (`github_issues "GitHubIssues", enabled: true`).
      #
      # It is off when the world declares nothing: a run finding stays a work item in Tickets and
      # `OpenIssueWhenRunReported` reaches no GitHub. Turning it on is one line in the world.
      module Switch
        # The world verb that carries the switch.
        VERB = "github_issues"

        # The `source` of a finding that a failed run filed.
        RUN_SOURCE = "qa_loop"

        # Whether a registry's Tickets world turns GitHub issues for run findings on.
        #
        # @param registry [Runtime::Registry, nil] the booted registry whose world is read
        # @return [Boolean] true only when the world declares `enabled: true`
        def self.enabled?(registry)
          declared = registry&.world("Tickets")&.for_verb(VERB)
          [true, "true"].include?(declared && declared[:enabled])
        end

        # Refuses, before any `gh` call, an issue for a run finding while the switch is off.
        #
        # @param held [Hash] the finding's fields
        # @param registry [Runtime::Registry, nil]
        # @raise [FindingGithub::Error] naming the setting that turns it on
        def self.guard!(held, registry)
          return unless held_source(held) == RUN_SOURCE
          return if enabled?(registry)

          raise FindingGithub::Error, "GitHub issues for run findings are switched off: " \
                                      "set `#{VERB} \"GitHubIssues\", enabled: true` in the Tickets world"
        end

        # @param held [Hash] the finding's fields
        # @return [String, nil] its source, unwrapped from a value object
        def self.held_source(held)
          source = held[:source]
          source.is_a?(Hash) ? IndifferentKey.read(source, :value) : source
        end
      end
    end
  end
end
