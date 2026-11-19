# frozen_string_literal: true

require "cgi"
require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The planning page of a chosen project. `/plan` is the board's own project's, live;
      # `/plan/<name>` is the one the `ProjectBoard` row of that name keeps, drawn from its own
      # store when asked and only read: the page offers no step that changes it. Every planning
      # page carries the chooser, which lists the rows and goes to the page of the one picked.
      module ProjectPlans
        ROUTE = %r{\A/plan/(?<name>[A-Za-z0-9_-]{1,64})\z}
        # Where the chooser is drawn in the page file.
        CHOOSER = "<!--projects-->"
        # The page's `<main>`, marked with the project it shows when that is another's.
        MAIN = "<main>"

        module_function

        # @param path [String] a request path
        # @return [MatchData, nil] the route's `name`, nil for any other path
        def match(path) = ROUTE.match(path)

        # @param app [#project_plan_page]
        # @param route [MatchData] a {match} result
        # @return [Array(Integer, String, String)] the status, content type and body: the page, or
        #   404 when no `ProjectBoard` row has the name
        def answer(app, route)
          page = app.project_plan_page(route[:name])
          page ? [200, "text/html; charset=utf-8", page] : [404, "text/plain", "no project board is named #{route[:name]}"]
        end

        # @param chosen [String] the name of the project the page shows
        # @return [String] the chooser: a list of every `ProjectBoard` row, the chosen one selected
        def chooser(chosen)
          options = Rules.rows("ProjectBoard").map { |row| option(row, chosen) }.join
          "<label class=\"note\">Project <select id=\"project\" aria-label=\"Which project's plan\">#{options}</select></label>"
        end

        # @return [String] one row as an option, carrying the address of its page
        def option(row, chosen)
          name = CGI.escapeHTML(row[:name])
          href = row[:checkout].empty? ? "/plan" : "/plan/#{name}"
          "<option value=\"#{name}\" data-href=\"#{href}\"#{" selected" if row[:name] == chosen}>#{name}</option>"
        end

        # @return [String] the name of the board's own project: the row with no checkout
        def own = Rules.rows("ProjectBoard").find { |row| row[:checkout].empty? }.fetch(:name)

        # @param html [String] the page file
        # @param name [String] another project's name
        # @param tile [String] its plan tile, drawn
        # @return [String] the page showing that project, marked read-only for its script
        def foreign(html, name, tile)
          html.sub(CHOOSER) { chooser(name) }.sub("<!--tile:plan-->") { tile }
              .sub(MAIN) { "<main data-project=\"#{CGI.escapeHTML(name)}\" data-foreign=\"true\">" }
        end
      end
    end

    # Reopened here so the chosen project's page sits beside the route that reaches it.
    class PipelineWeb
      # @param name [String] a `ProjectBoard` name
      # @return [String, nil] its planning page; the board's own page for its own project; nil
      #   when no row has the name
      def project_plan_page(name)
        row = PipelineBoard::Rules.rows("ProjectBoard").find { |candidate| candidate[:name] == name }
        return nil unless row
        return plan_page if row[:checkout].empty?

        tile = PipelineBoard::PlanHtml.draw(@stages.project_plan_tile(name))
        PipelineBoard::ProjectPlans.foreign(File.read(PipelineBoard::PlanPage::PATH), name, tile)
      end
    end
  end
end
