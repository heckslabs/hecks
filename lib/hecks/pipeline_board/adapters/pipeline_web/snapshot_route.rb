# frozen_string_literal: true

require "uri"

module Hecks
  module Adapters
    module PipelineBoard
      # `GET /api/snapshot?width=&colour=&limit=`: the text panel `PipelineBoard.snapshot` prints,
      # drawn by the running board ({PanelCache}), so the launcher answers that question without a
      # boot. Until the board holds a fresh state it answers 503, and the launcher reads for itself.
      module SnapshotRoute
        PATH = "/api/snapshot"
        TEXT = "text/plain; charset=utf-8"

        module_function

        # @param app [#snapshot_panel] the board
        # @param query [String, nil] the request's query string
        # @return [Array(Integer, String, String)] the status, content type and body
        def answer(app, query)
          fields = URI.decode_www_form(query.to_s).to_h
          text = app.snapshot_panel(width: number(fields["width"]), colour: fields["colour"] == "true",
                                    limit: number(fields["limit"]))
          text ? [200, TEXT, text] : [503, TEXT, "the board holds no fresh state yet"]
        rescue ArgumentError
          [400, TEXT, "width and limit are whole numbers"]
        end

        # @return [Integer, nil] the field as a whole number, nil when it was not given
        # @raise [ArgumentError] when it is not a whole number
        def number(value) = value.to_s.empty? ? nil : Integer(value, 10)
      end
    end
  end
end
