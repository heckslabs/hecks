require "tempfile"
require_relative "commands"

module Hecks
  module Release
    class Runner
      # The npm step: publishes `@hecks/client` from `packages/hecks-client`
      # with the token 1Password holds.
      class NpmPublisher
        PACKAGE_DIR = "packages/hecks-client".freeze
        ENV_FILE = "release/npm_publish.env".freeze
        APPROVAL_NOTICE = "npm will print an approval link; open it and approve with your security key or passkey. " \
                          "This step waits for you.".freeze
        USERCONFIG_LINE = "//registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}".freeze

        def initialize(root:, commands:, console:)
          @root = root
          @commands = commands
          @console = console
        end

        # Publishes the package, or with `dry_run` only packs it, which needs no
        # credentials.
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

        # npm's `prepack` hook builds `dist/`; there is no separate build step here.
        def install_dependencies
          return if Dir.exist?(File.join(package_dir, "node_modules"))

          @console.say("Installing the client's dependencies (npm ci)...")
          @commands.run!("npm", "ci", chdir: package_dir)
        end

        # The token bypasses 2FA (the account's second factor is a passkey); this
        # fallback publish runs with `--auth-type=web` and doesn't capture output,
        # so an approval prompt reaches the terminal.
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
