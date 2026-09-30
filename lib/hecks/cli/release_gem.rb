# frozen_string_literal: true

require "json"
require_relative "../release/runner/commands"
require_relative "../hecks/adapters/codebase/gem_registry"
require_relative "../version"

module Hecks
  module CLI
    # The command behind `bin/release_gem`: builds the hecks gem and pushes it to rubygems.org,
    # using a push-scoped API key from 1Password instead of `~/.gem/credentials`. It pushes the
    # version `lib/hecks/version.rb` declares.
    module ReleaseGem
      module_function

      # Builds and pushes the gem, refusing unless `op` is installed and the JS client is at the
      # same version (`spec/hecks_client_version_spec.rb` pins that rule too).
      #
      # @param root [String] the repository root the gem is built from
      # @param commands [#run!, #capture, nil] runs the child commands; a real one when nil
      # @param out [IO] where progress goes
      # @param err [IO] where a refusal goes
      # @return [Integer] 0 once pushed, 1 when refused
      def call(root:, commands: nil, out: $stdout, err: $stderr)
        Dir.chdir(root) do
          commands ||= Hecks::Release::Runner::Commands.new
          registry = Hecks::Adapters::Codebase::GemRegistry.new(root: root, commands: commands)
          refusal = refusal_for(root, commands)
          if refusal
            err.puts refusal
            return 1
          end

          out.puts "Building and pushing hecks-#{Hecks::VERSION}.gem to rubygems.org " \
                   "(1Password will prompt for Touch ID)..."
          registry.push!(Hecks::VERSION)
          out.puts "Released hecks #{Hecks::VERSION}."
          0
        end
      end

      # @param root [String] the repository root
      # @param commands [#run!, #capture] runs the child commands
      # @return [String, nil] why the release cannot start, or nil when it can
      def refusal_for(root, commands)
        unless Hecks::Adapters::Codebase::SecretVault.new(commands: commands).installed?
          return "1Password CLI (op) not found. Install: brew install 1password-cli"
        end

        client_version = JSON.parse(File.read(File.join(root, "packages/hecks-client/package.json"))).fetch("version")
        return nil if client_version == Hecks::VERSION

        "packages/hecks-client is at #{client_version} but Hecks::VERSION is #{Hecks::VERSION}; bump the package first."
      end
    end
  end
end
