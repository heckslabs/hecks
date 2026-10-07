# frozen_string_literal: true

require "net/http"
require "openssl"
require_relative "../../../projections/site/probe"

module Hecks
  module Adapters
    class SiteToolchain
      # Sends a route table's probe requests to a running site and reports each answer.
      #
      # Every request is anonymous and follows no redirect, so a probe changes nothing on the site.
      class Prober
        # Seconds to wait to connect to the site, and again for its answer.
        TIMEOUT = 10

        # The failures of the network that fail one check rather than the whole run.
        NETWORK = [SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError].freeze

        # @param rows [Array<Projections::Site::Table::Row>] the checked rows of the route table
        # @param run [String] the run's name
        # @param base [String] the site's scheme, host and port
        def initialize(rows, run:, base:)
          @probe = Projections::Site::Probe.new(rows, run: run)
          @base = base
        end

        # @return [Array<(String, Integer)>] the report, one line per check ending in the count,
        #   and how many checks failed
        def call
          lines = @probe.checks.map { |check| judged(check) }
          failed = lines.count { |_, wrong| wrong }
          [lines.map(&:first).append("#{lines.size} checks, #{failed} failed").join("\n"), failed]
        end

        private

        # One check's line of the report: its label and `ok`, or the reason it failed.
        def judged(check)
          why = @probe.verdict(check, answer_to(check))
          ["  #{check.label}... #{why ? "FAILED: #{why}" : "ok"}", !why.nil?]
        rescue *NETWORK => e
          ["  #{check.label}... FAILED: #{e.class}: #{e.message}", true]
        end

        def answer_to(check)
          uri = URI.join(@base, check.path)
          request = Net::HTTP.const_get(check.verb.capitalize).new(uri)
          request["Origin"] = @base
          response = connection(uri).request(request)
          Projections::Site::Probe::Response.new(status: response.code.to_i, body: response.body,
                                                 headers: response.to_hash.transform_values(&:first))
        end

        def connection(uri)
          Net::HTTP.new(uri.host, uri.port).tap do |http|
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = http.read_timeout = TIMEOUT
          end
        end
      end
    end
  end
end
