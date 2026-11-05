# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # Judges a `POST /api/answer`: the origin, the content type and the body. The board's page is
      # the only client, so a cross-origin request is refused before its body is read, and a body
      # that is not a JSON object with `run` and `answer` strings is refused before the app sees it.
      module AnswerRoute
        PATH = "/api/answer"
        MAX_BODY = 64 * 1024

        module_function

        # @param path [String] the request path
        # @param headers [Hash{String => String}] the request headers, names downcased
        # @param allowed [Array<String>] the origins the board's own page is served from
        # @return [Array(Integer, String), nil] the refusal's status and reason, or nil to read
        #   the body
        def refusal(path, headers, allowed)
          return [404, "not found"] unless path == PATH
          return [403, "cross-origin request refused"] unless same_origin?(headers["origin"], allowed)
          return [415, "answer takes application/json"] unless json?(headers["content-type"])

          nil
        end

        def same_origin?(origin, allowed) = origin.nil? || allowed.include?(origin)

        def json?(type) = type.to_s.downcase.start_with?("application/json")

        # @param headers [Hash{String => String}] the request headers
        # @return [Integer] the body's length, or 0 when it is absent or larger than {MAX_BODY}
        def length_of(headers)
          length = headers["content-length"].to_i
          length.positive? && length <= MAX_BODY ? length : 0
        end

        # @param app [#answer] what runs the answer
        # @param raw [String] the request body
        # @return [Array(Integer, Hash)] the status and the JSON body to send
        def submit(app, raw)
          held = JSON.parse(raw)
          return [400, { error: "answer takes run and answer" }] unless answer?(held)

          [200, app.answer(run: held["run"], answer: held["answer"])]
        rescue JSON::ParserError
          [400, { error: "body is not JSON" }]
        rescue PipelineBoard::Unavailable => e
          [422, { error: e.message }]
        end

        # @return [Boolean] whether the body names a run and says an answer
        def answer?(held) = held.is_a?(Hash) && held["run"].is_a?(String) && held["answer"].is_a?(String)
      end
    end
  end
end
