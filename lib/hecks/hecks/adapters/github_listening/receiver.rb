# frozen_string_literal: true

require "hecks/adapters/driving/github_webhook"
require_relative "facts"

module Hecks
  module Adapters
    class GithubListening
      # The rack app the listener serves: one path, `POST /github-webhook`, signed with the secret.
      # The signature check, the method check and the body cap are {Driving::GithubWebhook}'s; this
      # answers any other path 404 and offers each signed delivery to `GithubEvent.Record`. A
      # delivery the domain refuses (a kind the pipeline does not follow, a delivery already
      # recorded) is answered 202 and nothing is written: GitHub must not send it again.
      class Receiver < Driving::GithubWebhook
        # The one path the listener answers.
        PATH = "/github-webhook"

        # The longest body taken: GitHub's payloads for the followed kinds are far smaller.
        MAX_BYTES = 1_048_576

        # @param secret [String] the shared webhook secret
        # @param record [#call] takes the `Record` command's arguments and raises one of
        #   `Runtime::DOMAIN_REFUSALS` when the domain refuses them
        def initialize(secret:, record:)
          super(secret: secret, max_bytes: MAX_BYTES)
          @record = record
        end

        # @param env [Hash] the rack environment
        # @return [Array(Integer, Hash, Array<String>)] 404 for any path but `/github-webhook`,
        #   else the webhook's own answer
        def call(env)
          return respond(404, error: "NotFound", message: "only POST #{PATH} is served") unless env["PATH_INFO"] == PATH

          super
        end

        private

        def handle_event(event, _action, payload, delivery: nil)
          @record.call({ delivery: delivery.to_s, kind: event }.merge(Facts.of(event, payload)))
          [202, { recorded: delivery }]
        rescue *Runtime::DOMAIN_REFUSALS => e
          [202, { ignored: delivery, reason: e.message }]
        end
      end
    end
  end
end
