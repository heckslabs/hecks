# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      class ProjectStore
        # Where a checkout keeps its Tickets store, read from the text of its own local worlds
        # (`*.local.world`, gitignored, naming absolute files). The world is read as text and never
        # loaded as Ruby, so no registry is made current while a request reads it, and nothing of
        # the project runs.
        module WorldPath
          # The local worlds a checkout holds, at most three directories down.
          GLOB = "{,*/,*/*/,*/*/*/}*.local.world"
          # Directories whose worlds are another project's or a copy's, never the checkout's own.
          SKIPPED = %w[vendor node_modules .claude tmp].freeze
          # Where one world's declaration starts.
          WORLD = /^\s*Hecks\.world\s*\(?\s*"/
          # A world bound to SQLite, and the database file it names.
          DATABASE = /persisted_by\s*\(?\s*"SqlitePersistence"\s*\)?.*?database\s*\(?\s*"([^"]+)"/m

          module_function

          # @param checkout [String] the project's checkout
          # @return [String, nil] the database its `Tickets` world names, nil when none does
          def database(checkout)
            worlds(checkout).each do |path|
              found = tickets_database(File.read(path))
              return File.expand_path(found, File.dirname(path)) if found
            end
            nil
          end

          # @param checkout [String]
          # @return [Array<String>] the checkout's own local worlds, in name order
          def worlds(checkout)
            found = Dir.glob(File.join(checkout, GLOB))
            found.reject { |path| path.delete_prefix("#{checkout}/").split("/").intersect?(SKIPPED) }
          end

          # @param text [String] a world file's text
          # @return [String, nil] the database the file's `Tickets` world names
          def tickets_database(text)
            declared = text.split(WORLD).find { |world| world.start_with?("Tickets\"") }
            declared && declared[DATABASE, 1]
          end
        end
      end
    end
  end
end
