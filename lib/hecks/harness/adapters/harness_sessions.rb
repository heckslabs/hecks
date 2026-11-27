# frozen_string_literal: true

require "hecks/harness/supervisor"

module Hecks
  module Adapters
    # The `Sessions` port's adapter for the Harness: it asks the running supervisor
    # ({Harness::Supervisor.current}) to start a session's child and to close it. With no
    # supervisor running, every ask is refused.
    class HarnessSessions
      def initialize(**); end

      # @return [Hash] the session's `pid`, once its child started
      # @raise [Harness::Supervisor::Refused] when the supervisor refuses, or none runs
      def open_session(name:, brief:, **)
        { pid: supervisor.open(name: plain(name), brief: plain(brief))["pid"].to_i }
      end

      # @return [Hash] nothing more: the child's exit is told later
      # @raise [Harness::Supervisor::Refused] when no supervisor runs
      def stop_session(name:, **)
        supervisor.stop(name: plain(name))
        {}
      end

      private

      def supervisor = Harness::Supervisor.current || raise(Harness::Supervisor::Refused, "no supervisor is running")

      def plain(value) = value.is_a?(Hash) ? value[:value] : value
    end
  end
end
