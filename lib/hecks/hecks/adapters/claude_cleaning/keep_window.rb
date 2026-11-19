# frozen_string_literal: true

module Hecks
  module Adapters
    class ClaudeCleaning
      # How long {PlainSweep} keeps a finished session no run holds, and whether a pin keeps it.
      #
      # A session the pipeline launched carries a caller name in its job ({ClaudeJobs#launched_by});
      # such a helper is kept `helper_minutes`. A session without one is the owner's, started by
      # hand, and is kept `owner_hours`, as is a helper when `helper_minutes` is 0. A session
      # `pins.json` names, or whose name or caller role is a `PinnedRole`, is never removed.
      class KeepWindow
        # @param owner_hours [Numeric] how long the owner's finished session stays listed
        # @param helper_minutes [Integer] how long a finished helper session stays listed, 0 for
        #   as long as the owner's
        # @param jobs [ClaudeJobs] reads a session's caller name and the pins
        # @param pinned [Array<String>] the roles whose session is never removed
        def initialize(owner_hours:, helper_minutes:, jobs:, pinned: [])
          @owner = owner_hours.to_f * 3600
          @helper = helper_minutes.to_i * 60
          @jobs = jobs
          @pinned = pinned
        end

        # @param entry [Hash] the session as `claude agents` lists it
        # @return [String, nil] why a pin keeps the session, nil when none does
        def pin(entry)
          return "pinned" if @jobs.pinned?(entry["id"].to_s)

          "pinned role" if [entry["name"].to_s, role(entry)].any? { |name| pinned_role?(name) }
        end

        # @param entry [Hash] the session as `claude agents` lists it
        # @return [Float] the seconds the session stays listed after it last wrote
        def seconds(entry) = helper?(entry) ? @helper.to_f : @owner

        private

        def helper?(entry) = @helper.positive? && !caller_name(entry).empty?

        def role(entry) = caller_name(entry).include?(":") ? caller_name(entry).split(":").first : ""

        def caller_name(entry) = @jobs.launched_by(entry["id"].to_s)

        def pinned_role?(name) = !name.empty? && @pinned.any? { |role| name.start_with?(role) }
      end
    end
  end
end
