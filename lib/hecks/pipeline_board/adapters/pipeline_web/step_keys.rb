# frozen_string_literal: true

require "securerandom"

module Hecks
  module Adapters
    module PipelineBoard
      # The key a plan and an owner's post each carry, made by the board and never taken from the
      # page, so a request cannot choose the key of a message or a plan.
      module StepKeys
        module_function

        # @param action [String] the step the page asked for
        # @param fields [Hash{Symbol => String}] the request's fields
        # @param root [String] the checkout a plan is made in
        # @return [Hash{Symbol => String}] the fields, with a key when the step needs one
        def fill(action, fields, root)
          case action
          when "plan" then fields.merge(repo: root, key: "plan-#{Time.now.to_i}")
          when "post" then fields.merge(key: "owner-#{Time.now.to_i}-#{SecureRandom.hex(2)}")
          else fields
          end
        end
      end
    end
  end
end
