require "tempfile"
require_relative "commands"

module Hecks
  module Release
    class Runner
      # The npm step: publishes `@hecks/client` from `packages/hecks-client`
      # with the token 1Password holds.
      #
      # `op run` resolves `release/npm_publish.env` into the environment of the
      # one `npm publish` process. npm reads its token from a config file, so a
      # throwaway user config holds a placeholder that npm expands from that
      # environment; the file never contains the token and is deleted afterwards.
      # The package's `prepack` builds `dist/`.
      #
      # npm's second factor is a security key or passkey approved in the browser,
      # so the publish runs with `--auth-type=web` and its output is not captured:
      # npm prints an approval link straight to the terminal and waits for it.
      class NpmPublisher
        PACKAGE_DIR = "packages/hecks-client".freeze
        ENV_FILE = "release/npm_publish.env".freeze
        APPROVAL_NOTICE = "npm will print an approval link; open it and approve with your security key or passkey. " \
                          "This step waits for you.".freeze
        USERCONFIG_LINE = "//registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}".freeze

        # @param root [String] the repository root
        # @param commands [#run!] runs npm and op
        # @param console [Console] progress output
        def initialize(root:, commands:, console:)
          @root = root
          @commands = commands
          @console = console
        end

        # Publishes the package, or with `dry_run` only packs it.
        #
        # @param version [String] the version being released
        # @param dry_run [Boolean] run `npm publish --dry-run`, which needs no credentials
        # @return [void]
        # @raise [CommandFailed] if installing, building or publishing fails
        def publish!(version, dry_run:)
          install_dependencies
          if dry_run
            @console.say("Dry run: npm publish --dry-run for @hecks/client #{version} (nothing is published)...")
            @commands.run!("npm", "publish", "--dry-run", "--access", "public", chdir: package_dir)
          else
            @console.say("Publishing @hecks/client #{version} to npm (1Password will prompt for Touch ID)...")
            @console.say(APPROVAL_NOTICE)
            publish_with_token
          end
        end

        private

        def package_dir
          File.join(@root, PACKAGE_DIR)
        end

        def install_dependencies
          return if Dir.exist?(File.join(package_dir, "node_modules"))

          @console.say("Installing the client's dependencies (npm ci)...")
          @commands.run!("npm", "ci", chdir: package_dir)
        end

        def publish_with_token
          with_userconfig do |userconfig|
            @commands.run!(
              "op", "run", "--env-file=#{File.join(@root, ENV_FILE)}", "--",
              "npm", "publish", "--access", "public", "--auth-type=web", "--userconfig", userconfig,
              chdir: package_dir
            )
          end
        end

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
