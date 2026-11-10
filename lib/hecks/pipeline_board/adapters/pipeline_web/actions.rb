# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The steps the page may take, each one launcher command. The bluebook's `ActionRule` rows say
      # which steps exist, the fields each request must carry, whether it runs only with `confirm`,
      # which program runs it and the arguments. Nothing else reaches the launcher, so the page can
      # take these steps and no others. This module fills the arguments in and checks the request
      # against the row; it decides nothing.
      module Actions
        # A `{field}` in an `ActionRule` argument, filled from the request.
        PLACEHOLDER = /\{(\w+)\}/

        module_function

        # @param action [Object] the step the request names
        # @return [Boolean] whether the board knows the step
        def known?(action) = action.is_a?(String) && !Rules.action(action).nil?

        # @param action [String] a known step
        # @param fields [Hash{Symbol => String}] the request's fields
        # @param confirm [Boolean] whether the request confirms the step
        # @return [Array<String>] the launcher's arguments for the step
        # @raise [PipelineBoard::Unavailable] when a field is missing or the step is not confirmed
        def argv(action, fields, confirm:)
          rule = Rules.action(action)
          check(action, rule, fields, confirm)
          rule[:argv].split.map { |word| filled(word, fields) }
        end

        # @param action [String] a known step
        # @param fields [Hash{Symbol => String}] the request's fields
        # @return [Array<String>, nil] the launcher's arguments for the command the step runs first
        def before(action, fields)
          words = Rules.action(action)[:before].to_s.split
          words.map { |word| filled(word, fields) } unless words.empty?
        end

        # @param action [String] a known step
        # @return [String, nil] the step taken instead when the run the step names has ended
        def ended(action)
          step = Rules.action(action)[:ended].to_s
          step unless step.empty?
        end

        def check(action, rule, fields, confirm)
          missing = rule[:needs].reject { |name| fields[name].is_a?(String) }
          raise PipelineBoard::Unavailable, "#{action} needs #{missing.join(", ")}" unless missing.empty?
          raise PipelineBoard::Unavailable, "#{action} runs only with confirm" if rule[:confirm] && !confirm
        end

        def filled(word, fields) = word.gsub(PLACEHOLDER) { fields[Regexp.last_match(1).to_sym].to_s }

        # @param action [String] a known step
        # @return [String] the program the step runs
        def program(action) = Rules.action(action)[:program]

        # The mode a resumed session keeps: the one it was launched with, when the board knows it.
        def permission_flags(mode) = mode.to_s.empty? ? [] : ["--permission-mode", mode]
      end
    end
  end
end
