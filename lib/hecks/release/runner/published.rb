require "json"
require_relative "commands"

module Hecks
  module Release
    class Runner
      # Asks the registries whether a version is already out, so a re-run of the
      # release skips what an earlier run finished.
      #
      # Neither question needs credentials.
      class Published
        GEM_VERSIONS_URL = "https://rubygems.org/api/v1/versions/hecks.json".freeze
        NPM_PACKAGE = "@hecks/client".freeze

        # @param root [String] the repository root
        # @param commands [#capture] runs curl and npm
        def initialize(root:, commands:)
          @root = root
          @commands = commands
        end

        # Says whether RubyGems lists the hecks gem at a version.
        #
        # @param version [String] the version to look for
        # @return [Boolean] true when it is published
        # @raise [Refusal] if RubyGems cannot be reached or answers with something unreadable
        def gem?(version)
          result = @commands.capture("curl", "-fsS", GEM_VERSIONS_URL, chdir: @root)
          unless result.success?
            raise Refusal, "could not list published hecks versions (#{result.stderr.strip}); " \
                           "check the network and re-run"
          end

          JSON.parse(result.stdout).any? { |entry| entry["number"] == version }
        rescue JSON::ParserError
          raise Refusal, "RubyGems answered with something other than a version list; re-run in a minute"
        end

        # Says whether npm lists @hecks/client at a version.
        #
        # @param version [String] the version to look for
        # @return [Boolean] true when it is published
        # @raise [Refusal] if npm fails for any reason other than the version not existing
        def npm?(version)
          result = @commands.capture("npm", "view", "#{NPM_PACKAGE}@#{version}", "version", chdir: @root)
          return result.stdout.strip == version if result.success?
          return false if result.stderr.include?("E404")

          raise Refusal, "could not check npm for #{NPM_PACKAGE}@#{version} (#{result.stderr.strip.lines.first}); " \
                         "check the network and re-run"
        end
      end
    end
  end
end
