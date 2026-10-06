module Hecks
  module Release
    class Runner
      # Which steps to run and how.
      class Options
        # The switches, each off unless a caller turns it on.
        FLAGS = %i[dry_run gem_only npm_only npm_local no_wait yes].freeze

        # @return [Boolean] run every check and build, but tag, push and publish nothing
        attr_reader :dry_run

        # @param flags [Hash{Symbol => Boolean}] any of:
        #   `dry_run` run every check and build, but tag, push and publish nothing;
        #   `gem_only` publish the gem, not the package;
        #   `npm_only` do the npm step only, not the gem: wait for CI's publish, or with `npm_local`
        #   publish from here;
        #   `npm_local` publish the package from this machine, not by CI;
        #   `no_wait` do not wait for CI's publish to reach npm;
        #   `yes` answer every confirmation yes
        # @raise [ArgumentError] if the flags contradict each other, or one is not a switch
        def initialize(**flags)
          unknown = flags.keys - FLAGS
          raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

          check_flags(flags)
          @dry_run = flags.fetch(:dry_run, false)
          @gem_only = flags.fetch(:gem_only, false)
          @npm_only = flags.fetch(:npm_only, false)
          @npm_local = flags.fetch(:npm_local, false)
          @no_wait = flags.fetch(:no_wait, false)
          @yes = flags.fetch(:yes, false)
        end

        # Says whether confirmations are answered automatically.
        #
        # @return [Boolean] true under `--yes`
        def yes?
          @yes
        end

        # Says whether the gem step is in scope.
        #
        # @return [Boolean] true unless `--npm-only`
        def gem?
          !@npm_only
        end

        # Says whether the npm step is in scope.
        #
        # @return [Boolean] true unless `--gem-only`
        def npm?
          !@gem_only
        end

        # Says whether the package is published from this machine.
        #
        # @return [Boolean] true under `--npm-local`
        def npm_local?
          @npm_local
        end

        # Says whether to wait for CI's publish to reach npm.
        #
        # @return [Boolean] true unless `--no-wait`
        def wait?
          !@no_wait
        end

        private

        def check_flags(flags)
          gem_only, npm_only, npm_local, no_wait = flags.values_at(:gem_only, :npm_only, :npm_local, :no_wait)
          raise ArgumentError, "--gem-only and --npm-only cannot be combined" if gem_only && npm_only
          raise ArgumentError, "--gem-only and --npm-local cannot be combined" if gem_only && npm_local
          return unless no_wait && npm_local

          raise ArgumentError, "--no-wait applies to CI's publish, so it cannot be combined with --npm-local"
        end
      end
    end
  end
end
