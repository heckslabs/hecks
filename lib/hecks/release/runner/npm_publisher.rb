require_relative "commands"
require "hecks/hecks/adapters/codebase/npm_registry"

module Hecks
  module Release
    class Runner
      # The npm step: publishes `@hecks/client` from `packages/hecks-client`
      # with the token 1Password holds.
      class NpmPublisher
        APPROVAL_NOTICE = "npm will print an approval link; open it and approve with your security key or passkey. " \
                          "This step waits for you.".freeze

        def initialize(root:, commands:, console:)
          @root = root
          @console = console
          @registry = Hecks::Adapters::Codebase::NpmRegistry.new(root: root, commands: commands)
        end

        # Publishes the package, or with `dry_run` only packs it, which needs no
        # credentials.
        def publish!(version, dry_run:)
          install_dependencies
          if dry_run
            @console.say("Dry run: npm publish --dry-run for @hecks/client #{version} (nothing is published)...")
            @registry.dry_publish!
          else
            @console.say("Publishing @hecks/client #{version} to npm (1Password will prompt for Touch ID)...")
            @console.say(APPROVAL_NOTICE)
            @registry.publish!
          end
        end

        private

        # npm's `prepack` hook builds `dist/`; there is no separate build step here.
        def install_dependencies
          return if @registry.installed?

          @console.say("Installing the client's dependencies (npm ci)...")
          @registry.install!
        end
      end
    end
  end
end
