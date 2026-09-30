# frozen_string_literal: true

require "optparse"
require_relative "../release/runner"

module Hecks
  module CLI
    # The command behind `hecks publish`: tags the merged release commit, publishes the gem, and
    # gets `@hecks/client` published to npm. See "Releasing" in CONTRIBUTING.md for the release PR.
    #
    #   hecks publish --dry-run    # every check and build, nothing tagged or published
    #   hecks publish              # tag, gem, then wait for CI to publish the client
    module Release
      # The flags a run starts with, before any is named.
      DEFAULT_FLAGS = { dry_run: false, gem_only: false, npm_only: false, npm_local: false,
                        no_wait: false, yes: false }.freeze

      module_function

      # Parses the flags and runs the release.
      #
      # @param argv [Array<String>] the command line's flags
      # @param root [String] the repository root the release runs in
      # @return [Integer] the release's exit status, or 2 for a flag it does not know
      def call(argv, root:)
        argv = argv.dup
        flags = DEFAULT_FLAGS.dup
        parser = parser_for(flags)
        begin
          parser.parse!(argv)
          raise OptionParser::InvalidArgument, argv.join(" ") unless argv.empty?

          return 0 if flags.delete(:help)

          options = Hecks::Release::Runner::Options.new(**flags)
        rescue OptionParser::ParseError, ArgumentError => e
          warn "hecks publish: #{e.message}"
          warn parser
          return 2
        end

        Hecks::Release::Runner.new(root: root, options: options).call
      end

      # @param flags [Hash{Symbol => Boolean}] filled in as the parser reads each flag
      # @return [OptionParser] the parser for `hecks publish`'s flags
      def parser_for(flags)
        OptionParser.new do |opts|
          opts.banner = "Usage: hecks publish [--dry-run] [--gem-only | --npm-only] [--npm-local | --no-wait] [--yes]"
          opts.separator("Tags the merged release commit, publishes the gem, and gets @hecks/client published.")
          opts.separator("By default CI publishes the client from the tag and this waits for it.")
          opts.on("--dry-run", "run every check and build; tag, push and publish nothing") { flags[:dry_run] = true }
          opts.on("--gem-only", "publish the gem only") { flags[:gem_only] = true }
          opts.on("--npm-only", "skip the gem: wait for CI's publish, or with --npm-local publish from here") do
            flags[:npm_only] = true
          end
          opts.on("--npm-local", "publish @hecks/client from this machine (first publish, or CI is down)") do
            flags[:npm_local] = true
          end
          opts.on("--no-wait", "do not wait for CI's publish to reach npm") { flags[:no_wait] = true }
          opts.on("--yes", "answer the confirmations yes") { flags[:yes] = true }
          opts.on("--help", "print this usage") do
            puts opts
            flags[:help] = true
          end
        end
      end
    end
  end
end
