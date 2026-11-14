# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The CI page, answered by the board's web adapter at `/ci`: main's runs and the train pull
      # requests', the slowest jobs and the flakes. The page reads the board's state and its
      # stream, so serving it reads nothing but the file.
      module CiPage
        # The page file.
        PATH = File.expand_path("ci.html", __dir__)

        # @return [String] the CI page
        def ci_page = File.read(PATH)
      end
    end

    # Reopened here so the CI page's reader sits beside the page it reads.
    class PipelineWeb
      include PipelineBoard::CiPage
    end
  end
end
