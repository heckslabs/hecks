# frozen_string_literal: true

require_relative "../journal_store/held_mint"
require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # The check that the mint is made for the shape being pushed.
      #
      # The mint reads the bluebooks of the code running the train (its launcher), not those of the
      # repository being pushed. When both are checkouts of one repository, the launcher's `HEAD`
      # must carry the same bluebooks, hecksagons, worlds and shape ledger as the boarded commit;
      # if it does not, the boarding is refused with "the train is not at the boarded commit:
      # refresh it first". A repository the launcher is not a checkout of, or one that holds no
      # Hecks domain directory, has no launcher shape to compare and passes.
      #
      # The comparison is one `git diff --quiet` between the launcher's `HEAD` and the boarded
      # commit, limited to the shape files of the Hecks domain directory: one git call.
      class LauncherShape
        include Reading

        # The files of a domain directory that make up its shape.
        SHAPE = %w[*.bluebook *.hecksagon *.world shapes.json].freeze

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level the boarding is for
        # @param domain [String] the launcher's Hecks domain directory
        def initialize(git, checkout, domain: JournalStore::HeldMint::DOMAIN)
          @git = git
          @checkout = checkout
          @domain = domain
        end

        # @param boarded [String] the commit being boarded
        # @return [void]
        # @raise [ConsoleCapture::Failure] when the launcher's checkout is of the same repository
        #   and its `HEAD` differs from the boarded commit in the shape files
        def check!(boarded)
          return unless File.directory?(@domain)

          top = launcher_top
          return unless top && same_repository?(top)

          relative = File.realpath(@domain).delete_prefix("#{top}/")
          launcher = read("rev-parse", "--verify", "HEAD^{commit}", dir: top)
          return if same_shape?(launcher, boarded, relative)

          raise ConsoleCapture::Failure,
                "the train is not at the boarded commit: refresh it first (it runs #{short(launcher)}, " \
                "the boarding is #{short(boarded)}, and their shape files in #{relative} differ)"
        end

        private

        def same_shape?(launcher, boarded, relative)
          paths = SHAPE.map { |name| ":(glob)#{relative}/**/#{name}" }
          @git.capture("diff", "--quiet", launcher, boarded, "--", *paths, chdir: @checkout).ok?
        end

        def launcher_top
          result = @git.capture("rev-parse", "--show-toplevel", chdir: @domain)
          result.ok? ? File.realpath(result.out.strip) : nil
        end

        def same_repository?(top)
          common = ->(dir) { @git.capture("rev-parse", "--path-format=absolute", "--git-common-dir", chdir: dir).out.strip }
          File.realpath(common.call(top)) == File.realpath(common.call(@checkout))
        rescue SystemCallError
          false
        end
      end
    end
  end
end
