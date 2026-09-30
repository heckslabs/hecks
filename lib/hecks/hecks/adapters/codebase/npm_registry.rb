# frozen_string_literal: true

require "tempfile"
require "hecks/release/runner/commands"
require_relative "secret_vault"

module Hecks
  module Adapters
    module Codebase
      # The `NpmRegistry` adapter: what a release does with npm and the `@hecks/client` package.
      #
      # It asks npm whether a version is out (no credentials), installs the package's
      # dependencies, and publishes it, either as a dry run (a pack, no credentials) or with the
      # token the SecretVault holds. The token bypasses 2FA, so the publish runs with
      # `--auth-type=web` and its output is not captured: the approval link reaches the terminal.
      class NpmRegistry
        # The package, by name.
        PACKAGE = "@hecks/client"

        # Where the package stands, relative to the checkout.
        PACKAGE_DIR = "packages/hecks-client"

        # The env file `op run` reads the publish token from, relative to the checkout.
        ENV_FILE = "release/npm_publish.env"

        # The npmrc line that reads the token from the environment `op run` sets.
        USERCONFIG_LINE = "//registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}"

        # @param root [String] the checkout's root
        # @param commands [#capture, #run!] starts each process
        # @param vault [SecretVault, nil] holds the publish token; one over `commands` when nil
        def initialize(root:, commands:, vault: nil)
          @root = root
          @commands = commands
          @vault = vault || SecretVault.new(commands: commands)
        end

        # Says whether npm lists the package at a version.
        #
        # @param version [String] the version to look for
        # @return [Boolean] true when it is published
        # @raise [Hecks::Release::Runner::Refusal] when npm fails for any reason other than the
        #   version not existing
        def published?(version)
          result = @commands.capture("npm", "view", "#{PACKAGE}@#{version}", "version", chdir: @root)
          return result.stdout.strip == version if result.success?
          return false if result.stderr.include?("E404")

          raise Release::Runner::Refusal,
                "could not check npm for #{PACKAGE}@#{version} (#{result.stderr.strip.lines.first}); " \
                "check the network and re-run"
        end

        # @return [Boolean] whether the package's dependencies are already installed
        def installed?
          Dir.exist?(File.join(package_dir, "node_modules"))
        end

        # Installs the package's dependencies with `npm ci`.
        #
        # @return [void]
        # @raise [Hecks::Release::Runner::CommandFailed] when it fails
        def install!
          @commands.run!("npm", "ci", chdir: package_dir)
        end

        # Packs the package and publishes nothing.
        #
        # @return [void]
        # @raise [Hecks::Release::Runner::CommandFailed] when the pack fails
        def dry_publish!
          @commands.run!("npm", "publish", "--dry-run", "--access", "public", chdir: package_dir)
        end

        # Publishes the package with the token the vault holds.
        #
        # @return [void]
        # @raise [Hecks::Release::Runner::CommandFailed] when the publish fails
        def publish!
          with_userconfig do |userconfig|
            @vault.run!(File.join(@root, ENV_FILE), "npm", "publish", "--access", "public", "--auth-type=web",
                        "--userconfig", userconfig, chdir: package_dir)
          end
        end

        private

        def package_dir = File.join(@root, PACKAGE_DIR)

        def with_userconfig
          file = Tempfile.new(["hecks-npmrc", ".npmrc"])
          file.chmod(0o600)
          file.write("#{USERCONFIG_LINE}\n")
          file.flush
          yield file.path
        ensure
          file&.close!
        end
      end
    end
  end
end
