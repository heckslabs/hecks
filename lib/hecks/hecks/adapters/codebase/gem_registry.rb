# frozen_string_literal: true

require "fileutils"
require "json"
require "hecks/release/runner/commands"
require_relative "secret_vault"

module Hecks
  module Adapters
    module Codebase
      # The `GemRegistry` adapter: what a release does with rubygems.org and the `gem` program.
      #
      # It asks the registry which versions are out (over `curl`, no credentials), builds the gem
      # from the checkout's gemspec, and pushes it with the key the SecretVault holds. A built gem
      # file is always deleted again, whether the push worked or not.
      class GemRegistry
        # Where RubyGems lists the published versions of the gem.
        VERSIONS_URL = "https://rubygems.org/api/v1/versions/hecks.json"

        # The env file `op run` reads the push key from, relative to the checkout.
        ENV_FILE = "release/gem_push.env"

        # @param root [String] the checkout's root
        # @param commands [#capture, #run!] starts each process
        # @param vault [SecretVault, nil] holds the push key; one over `commands` when nil
        def initialize(root:, commands:, vault: nil)
          @root = root
          @commands = commands
          @vault = vault || SecretVault.new(commands: commands)
        end

        # Says whether RubyGems lists the gem at a version.
        #
        # @param version [String] the version to look for
        # @return [Boolean] true when it is published
        # @raise [Hecks::Release::Runner::Refusal] when RubyGems cannot be reached or answers with
        #   something that is not a version list
        def published?(version)
          result = @commands.capture("curl", "-fsS", VERSIONS_URL, chdir: @root)
          unless result.success?
            raise Release::Runner::Refusal, "could not list published hecks versions (#{result.stderr.strip}); " \
                                            "check the network and re-run"
          end

          JSON.parse(result.stdout).any? { |entry| entry["number"] == version }
        rescue JSON::ParserError
          raise Release::Runner::Refusal, "RubyGems answered with something other than a version list; " \
                                          "re-run in a minute"
        end

        # Builds the gem, to prove it builds, and deletes it again.
        #
        # @param version [String] the version being released
        # @return [void]
        # @raise [Hecks::Release::Runner::CommandFailed] when the build fails
        def build_only!(version)
          @commands.run!("gem", "build", "hecks.gemspec", chdir: @root)
        ensure
          discard(version)
        end

        # Builds the gem and pushes it to rubygems.org, then deletes the file.
        #
        # @param version [String] the version being released
        # @return [void]
        # @raise [Hecks::Release::Runner::CommandFailed] when the build or the push fails
        def push!(version)
          @commands.run!("gem", "build", "hecks.gemspec", chdir: @root)
          @vault.run!(ENV_FILE, "gem", "push", "hecks-#{version}.gem", chdir: @root)
        ensure
          discard(version)
        end

        private

        def discard(version) = FileUtils.rm_f(File.join(@root, "hecks-#{version}.gem"))
      end
    end
  end
end
