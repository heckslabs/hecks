# frozen_string_literal: true

require_relative "deep_links"
require_relative "project_plans"
require_relative "snapshot_route"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's addresses that carry a key in their path or query: an item's deep link
      # ({DeepLinks}), another project's planning page ({ProjectPlans}) and the text panel
      # ({SnapshotRoute}).
      module PathLinks
        module_function

        # @param app [#page, #events_page, #run_detail, #train_detail, #project_plan_page,
        #   #snapshot_panel]
        # @param path [String] a request path
        # @param query [String, nil] the request's query string
        # @return [Array(Integer, String, String), nil] the status, content type and body, nil when
        #   the path carries no key
        def answer(app, path, query = nil)
          return SnapshotRoute.answer(app, query) if path == SnapshotRoute::PATH

          deep = DeepLinks.match(path)
          return DeepLinks.answer(app, deep) if deep

          project = ProjectPlans.match(path)
          ProjectPlans.answer(app, project) if project
        end
      end
    end
  end
end
