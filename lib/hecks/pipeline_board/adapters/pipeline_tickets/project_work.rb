# frozen_string_literal: true

require_relative "../rules"
require_relative "../rows"
require_relative "project_store"
require_relative "undone_rule"

module Hecks
  module Adapters
    module PipelineBoard
      # The `Tickets` port's `ProjectWork`: one project's epics and undone Work items, for the
      # planning page of the project chosen from the `ProjectBoard` rows. The row with no checkout
      # is the board's own project and is answered as `OpenWork` is; another is read from its own
      # store by {ProjectStore}, its undone items by the Tickets bluebook's `Work.Undone`
      # ({UndoneRule}). Mixed into {PipelineTickets}.
      module ProjectWork
        # @param project [Hash, String] a `ProjectBoard` name, or its value object
        # @return [Array<Hash>] the project's undone Work items as `WorkLine` rows
        # @raise [PipelineBoard::Unavailable] when no row names the project or its store cannot be
        #   read
        def project_work(project:)
          name = project.is_a?(Hash) ? project[:value].to_s : project.to_s
          Rows.of("WorkLine", project_reading(name)[:items])
        end

        # @param name [String] a `ProjectBoard` name
        # @return [Hash] `project`, `items` and `epics` as the planning page reads them, or
        #   `unknown: <reason>`
        def project_plan(name)
          project_reading(name)
        rescue PipelineBoard::Unavailable => e
          { unknown: e.message }
        end

        # @param name [String]
        # @return [Hash, nil] the `ProjectBoard` row of that name, nil when none is
        def project_board(name) = PipelineBoard::Rules.rows("ProjectBoard").find { |row| row[:name] == name }

        private

        def project_reading(name)
          row = project_board(name) or raise PipelineBoard::Unavailable, "no project board is named #{name}"
          return { project: name, items: undone, epics: epics } if row[:checkout].empty?

          read = project_store(row).read
          { project: name, items: foreign_items(read[:works]), epics: read[:epics].map { |e| epic_row(e, read[:works]) } }
        end

        def foreign_items(works) = undone_rule.apply(works).map { |work| item(work) }

        def undone_rule = (@undone_rule ||= PipelineBoard::UndoneRule.new(registry: @registry))

        # One store a project, kept so its database is found once.
        def project_store(row)
          (@project_stores ||= {})[row[:name]] ||=
            PipelineBoard::ProjectStore.new(checkout: File.join(projects_dir, row[:checkout]))
        end

        # The directory the projects' checkouts sit in: the one holding the board's own checkout.
        def projects_dir = @projects_dir || File.dirname(ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT") { Dir.pwd })
      end
    end
  end
end
