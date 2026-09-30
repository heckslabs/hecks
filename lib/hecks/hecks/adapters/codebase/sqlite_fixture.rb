# frozen_string_literal: true

require_relative "tree"
require_relative "../shell"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # The `SqliteFixture` adapter: regenerates the persistence legacy fixtures
      # (`spec/fixtures/persistence_legacy/`) by writing through the real adapters.
      #
      # The fixtures are a baseline that later adapters are compared with, so the run is never
      # started by accident: unconfirmed it reports what it would rewrite and whether the `sqlite3`
      # program it dumps a database with is installed, and writes nothing. Confirmed, it runs
      # `PersistenceLegacyFixture::Regenerate` in this process, which needs a reachable Postgres as
      # well.
      class SqliteFixture
        # Where the fixtures stand, relative to the checkout.
        DIRECTORY = "spec/fixtures/persistence_legacy"

        # The stores each fixture set is written for.
        STORES = %w[heki sqlite d1 postgres postgres_era].freeze

        # @param tree [Tree] the checkout whose fixtures are rewritten
        # @param shell [#capture, nil] starts the `sqlite3` probe; a `Shell` when nil
        # @param regenerator [#call, nil] rewrites the fixtures, as `call(dir:)` answering what was
        #   written; `PersistenceLegacyFixture::Regenerate` when nil
        def initialize(tree, shell: nil, regenerator: nil)
          @tree = tree
          @shell = shell || Shell.new
          @regenerator = regenerator
        end

        # Regenerates the fixtures, or reports what a regeneration would rewrite.
        #
        # @param confirm [Boolean] whether to rewrite
        # @return [String] what was written, or (unconfirmed) what would be
        # @raise [ConsoleCapture::Failure] when a fixture cannot be written
        def regenerate(confirm:)
          return rewrite if confirm

          "dry run, would rewrite #{DIRECTORY}/ for #{STORES.join(', ')} through the real adapters " \
            "(#{installed}; add --confirm)"
        end

        # @return [Boolean] whether the `sqlite3` program answers
        def sqlite_installed?
          @shell.capture("sqlite3", "--version").ok?
        end

        private

        def rewrite
          regenerator.call(dir: @tree.path(DIRECTORY))
        rescue LoadError, StandardError => e
          raise ConsoleCapture::Failure, "#{e.class}: #{e.message}"
        end

        def regenerator
          @regenerator ||= begin
            require "hecks/persistence_legacy_fixture"
            PersistenceLegacyFixture::Regenerate
          end
        end

        def installed = sqlite_installed? ? "sqlite3 is installed" : "sqlite3 is not installed"
      end
    end
  end
end
