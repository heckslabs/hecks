# frozen_string_literal: true

require_relative "deep_links"
require_relative "project_plans"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's addresses that carry a key in their path: an item's deep link ({DeepLinks})
      # and another project's planning page ({ProjectPlans}).
      module PathLinks
        module_function

        # @param app [#page, #events_page, #run_detail, #train_detail, #project_plan_page]
        # @param path [String] a request path
        # @return [Array(Integer, String, String), nil] the status, content type and body, nil when
        #   the path carries no key
        def answer(app, path)
          deep = DeepLinks.match(path)
          return DeepLinks.answer(app, deep) if deep

          project = ProjectPlans.match(path)
          ProjectPlans.answer(app, project) if project
        end
      end
    end
  end
end
