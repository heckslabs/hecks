# frozen_string_literal: true

require "json"
require_relative "actions"

module Hecks
  module Adapters
    module PipelineBoard
      # Judges a `POST /api/act`: the origin, the content type, the body and the step it names. The
      # board's page is the only client, so a cross-origin request is refused before its body is
      # read, and a body that names no known step is refused before the app sees it.
      module ActRoute
        PATH = "/api/act"
        MAX_BODY = 64 * 1024
        FIELDS = %w[target text session].freeze

        module_function

        # @param path [String] the request path
        # @param headers [Hash{String => String}] the request headers, names downcased
        # @param allowed [Array<String>] the origins the board's own page is served from
        # @return [Array(Integer, String), nil] the refusal's status and reason, or nil to read the
        #   body
        def refusal(path, headers, allowed)
          return [404, "not found"] unless path == PATH
          return [403, "cross-origin request refused"] unless same_origin?(headers["origin"], allowed)
          return [415, "act takes application/json"] unless json?(headers["content-type"])

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

        # @param app [#act] what runs the step
        # @param raw [String] the request body
        # @return [Array(Integer, Hash)] the status and the JSON body to send
        def submit(app, raw)
          held = JSON.parse(raw)
          return [400, { error: "act takes a known action" }] unless held.is_a?(Hash) && Actions.known?(held["action"])

          [200, app.act(action: held["action"], fields: fields_of(held), confirm: held["confirm"] == true)]
        rescue JSON::ParserError
          [400, { error: "body is not JSON" }]
        rescue PipelineBoard::Unavailable => e
          [422, { error: e.message }]
        end

        # @return [Hash{Symbol => String}] the text fields the body carries
        def fields_of(held)
          FIELDS.each_with_object({}) { |name, fields| fields[name.to_sym] = held[name] if held[name].is_a?(String) }
        end
      end
    end
  end
end
