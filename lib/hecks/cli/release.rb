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

      # Each flag's switch and its help line, in the order the usage lists them.
      FLAG_HELP = {
        dry_run:   ["--dry-run", "run every check and build; tag, push and publish nothing"],
        gem_only:  ["--gem-only", "publish the gem only"],
        npm_only:  ["--npm-only", "skip the gem: wait for CI's publish, or with --npm-local publish from here"],
        npm_local: ["--npm-local", "publish @hecks/client from this machine (first publish, or CI is down)"],
        no_wait:   ["--no-wait", "do not wait for CI's publish to reach npm"],
        yes:       ["--yes", "answer the confirmations yes"]
      }.freeze

      module_function

      # Parses the flags and runs the release.
      #
      # @param argv [Array<String>] the command line's flags
      # @param root [String] the repository root the release runs in
      # @return [Integer] the release's exit status, or 2 for a flag it does not know
      def call(argv, root:)
        argv = argv.dup
        flags = DEFAULT_FLAGS.dup
        options, status = parse_flags(parser_for(flags), argv, flags)
        return status unless options

        Hecks::Release::Runner.new(root: root, options: options).call
      end

      # Reads the flags into the run's options.
      #
      # @api private
      # @return [Array(Hecks::Release::Runner::Options, nil), Array(nil, Integer)] the options
      #   to run with, or no options and the exit status to stop with (0 for help, 2 for a bad flag)
      def parse_flags(parser, argv, flags)
        parser.parse!(argv)
        raise OptionParser::InvalidArgument, argv.join(" ") unless argv.empty?
        return [nil, 0] if flags.delete(:help)

        [Hecks::Release::Runner::Options.new(**flags), nil]
      rescue OptionParser::ParseError, ArgumentError => e
        warn "hecks publish: #{e.message}"
        warn parser
        [nil, 2]
      end

      # @param flags [Hash{Symbol => Boolean}] filled in as the parser reads each flag
      # @return [OptionParser] the parser for `hecks publish`'s flags
      def parser_for(flags)
        OptionParser.new do |opts|
          opts.banner = "Usage: hecks publish [--dry-run] [--gem-only | --npm-only] [--npm-local | --no-wait] [--yes]"
          opts.separator("Tags the merged release commit, publishes the gem, and gets @hecks/client published.")
          opts.separator("By default CI publishes the client from the tag and this waits for it.")
          FLAG_HELP.each { |key, (switch, help)| opts.on(switch, help) { flags[key] = true } }
          opts.on("--help", "print this usage") do
            puts opts
            flags[:help] = true
          end
        end
      end
    end
  end
end
