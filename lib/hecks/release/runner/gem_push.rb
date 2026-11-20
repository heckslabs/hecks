# frozen_string_literal: true

require "json"
require_relative "commands"
require_relative "../../hecks/adapters/codebase/gem_registry"
require_relative "../../hecks/adapters/codebase/secret_vault"
require_relative "../../version"

module Hecks
  module Release
    class Runner
      # Builds the hecks gem and pushes it to rubygems.org with a push-scoped API key from
      # 1Password instead of `~/.gem/credentials`. It refuses unless `op` is installed and the JS
      # client is at the same version (`spec/hecks_client_version_spec.rb` pins that rule too).
      class GemPush
        # @param root [String] the repository root the gem is built from
        # @param commands [#run!, #capture] runs the child commands
        def initialize(root:, commands:)
          @root = root
          @commands = commands
        end

        # @param version [String] the version to build and push
        # @return [String] what was released
        # @raise [Refusal] when `op` is missing or the JS client is at another version
        def push!(version)
          reason = refusal(version)
          raise Refusal, reason if reason

          Dir.chdir(@root) { Hecks::Adapters::Codebase::GemRegistry.new(root: @root, commands: @commands).push!(version) }
          "Released hecks #{version}."
        end

        # @param version [String] the version being released
        # @return [String, nil] why the release cannot start, or nil when it can
        def refusal(version)
          unless Hecks::Adapters::Codebase::SecretVault.new(commands: @commands).installed?
            return "1Password CLI (op) not found. Install: brew install 1password-cli"
          end

          client = JSON.parse(File.read(File.join(@root, "packages/hecks-client/package.json"))).fetch("version")
          return nil if client == version

          "packages/hecks-client is at #{client} but Hecks::VERSION is #{version}; bump the package first."
        end
      end
    end
  end
end
