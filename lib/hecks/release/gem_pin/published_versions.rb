require "json"
require "net/http"
require "uri"

module Hecks
  module Release
    class GemPin
      # Raised when a pin cannot be resolved or is refused.
      class Error < StandardError; end

      # The hecks releases RubyGems publishes, fetched on first use.
      #
      # `GemPin` takes any object answering `include?` and `newest_satisfying`,
      # so a caller with no network, or a spec, hands it a stand-in and this
      # class is never asked to dial out.
      class PublishedVersions
        URL = URI("https://rubygems.org/api/v1/versions/hecks.json")

        # Says whether RubyGems publishes a version.
        #
        # @param version [String, Gem::Version] the version to look for
        # @return [Boolean] true when it is in the published list, prereleases included
        # @raise [GemPin::Error] if RubyGems cannot be reached or does not answer with the list
        def include?(version)
          versions.include?(Gem::Version.new(version))
        end

        # Finds the newest stable release a requirement allows.
        #
        # @param requirement [Gem::Requirement] the constraint to satisfy
        # @return [Gem::Version, nil] the newest non-prerelease version that satisfies it, or nil
        # @raise [GemPin::Error] if RubyGems cannot be reached or does not answer with the list
        def newest_satisfying(requirement)
          versions.reject(&:prerelease?).select { |version| requirement.satisfied_by?(version) }.max
        end

        private

        def versions
          @versions ||= fetch
        end

        def fetch
          response = Net::HTTP.start(URL.host, URL.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
            http.get(URL.request_uri)
          end
          unless response.is_a?(Net::HTTPSuccess)
            raise Error, "could not list published hecks versions (RubyGems answered #{response.code})"
          end

          JSON.parse(response.body).map { |entry| Gem::Version.new(entry.fetch("number")) }
        rescue SocketError, Timeout::Error, SystemCallError => e
          raise Error, "could not reach RubyGems to check the hecks version (#{e.class})"
        end
      end
    end
  end
end
