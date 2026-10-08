# frozen_string_literal: true

require "json"
require "net/http"
require_relative "../../../projections/site/role_probe"

module Hecks
  module Adapters
    class SiteToolchain
      # Dispatches each role-declaring command to a host with no role and no actor, and reports
      # whether the host refused the caller.
      #
      # A host that does not enforce roles would run the command, so this talks only to a host on
      # this machine: the one a spec or a CI job started for the purpose.
      class RoleProber
        # The addresses that name this machine.
        LOOPBACK = %w[localhost 127.0.0.1 ::1 [::1]].freeze

        # Seconds to wait to connect to the host, and again for its answer.
        TIMEOUT = 10

        # The failures of the network that fail one check rather than the whole run.
        NETWORK = [SystemCallError, Timeout::Error, SocketError, JSON::ParserError].freeze

        # @param checks [Array<Projections::Site::RoleProbe::Check>] the commands to dispatch
        # @param base [String] the host's scheme, host and port
        # @raise [ConsoleCapture::Failure] when the host is not on this machine
        def initialize(checks, base:)
          @checks = checks
          @uri = URI.parse(base)
          return if LOOPBACK.include?(@uri.host)

          raise ConsoleCapture::Failure, "roles are checked against a host on this machine, not #{@uri.host}: " \
                                         "a host that does not enforce roles would run each command"
        end

        # @return [Array<(String, Integer)>] the report, one line per command ending in the count,
        #   and how many failed; a command whose synthesized arguments the host refused is counted
        #   as unchecked, not failed
        def call
          lines = @checks.map { |check| judged(check) }
          failed = lines.count { |_, state| state == :failed }
          unchecked = lines.count { |_, state| state == :unchecked }
          summary = "#{lines.size} commands, #{failed} failed, #{unchecked} unchecked"
          [lines.map(&:first).append(summary).join("\n"), failed]
        end

        private

        def judged(check)
          answer = answer_to(check)
          return [line(check, "unchecked: the host refused the arguments before the role"), :unchecked] if unchecked?(answer)

          why = Projections::Site::RoleProbe.verdict(check, answer)
          [line(check, why ? "FAILED: #{why}" : "ok"), why ? :failed : :ok]
        rescue *NETWORK => e
          [line(check, "FAILED: #{e.class}: #{e.message}"), :failed]
        end

        def unchecked?(answer) = Projections::Site::RoleProbe.unchecked?(answer)

        def line(check, outcome) = "  #{check.verb} (#{check.role}) is refused with no role... #{outcome}"

        def answer_to(check)
          request = Net::HTTP::Post.new(URI.join(@uri.to_s, "/dispatch"), "Content-Type" => "application/json")
          request.body = JSON.generate(verb: check.verb, with: check.arguments)
          JSON.parse(connection.request(request).body)
        end

        def connection
          Net::HTTP.new(@uri.host, @uri.port).tap do |http|
            http.open_timeout = http.read_timeout = TIMEOUT
          end
        end
      end
    end
  end
end
