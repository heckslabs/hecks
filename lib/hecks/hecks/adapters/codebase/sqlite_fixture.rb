# frozen_string_literal: true

require_relative "tree"
require_relative "ruby_child"

module Hecks
  module Adapters
    module Codebase
      # The `SqliteFixture` adapter: regenerates the persistence legacy fixtures
      # (`spec/fixtures/persistence_legacy/`) by writing through the real adapters.
      #
      # The fixtures are a baseline that later adapters are compared with, so the run is never
      # started by accident: unconfirmed it reports what it would rewrite and whether the `sqlite3`
      # program it dumps a database with is installed, and writes nothing. Confirmed, it runs
      # `bin/regenerate_persistence_legacy_fixtures` in a child process, which needs a reachable
      # Postgres as well.
      class SqliteFixture
        # Where the fixtures stand, relative to the checkout.
        DIRECTORY = "spec/fixtures/persistence_legacy"

        # The stores each fixture set is written for.
        STORES = %w[heki sqlite d1 postgres postgres_era].freeze

        # @param tree [Tree] the checkout whose fixtures are rewritten
        # @param shell [#capture, nil] starts each child process; a `Shell` when nil
        def initialize(tree, shell: nil)
          @tree = tree
          @shell = shell || Shell.new
        end

        # Regenerates the fixtures, or reports what a regeneration would rewrite.
        #
        # @param confirm [Boolean] whether to rewrite
        # @return [String] what was written, or (unconfirmed) what would be
        # @raise [ConsoleCapture::Failure] when the script ends badly
        def regenerate(confirm:)
          return RubyChild.new(@tree, shell: @shell).answer("regenerate_persistence_legacy_fixtures") if confirm

          "dry run, would rewrite #{DIRECTORY}/ for #{STORES.join(', ')} through the real adapters " \
            "(#{installed}; add --confirm)"
        end

        # @return [Boolean] whether the `sqlite3` program answers
        def sqlite_installed?
          @shell.capture("sqlite3", "--version").ok?
        end

        private

        def installed = sqlite_installed? ? "sqlite3 is installed" : "sqlite3 is not installed"
      end
    end
  end
end
