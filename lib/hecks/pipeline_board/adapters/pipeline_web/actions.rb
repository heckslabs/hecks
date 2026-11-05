# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The steps the page may take, each one launcher command. A step names the fields its request
      # must carry and whether it runs only with `confirm`. Nothing else reaches the launcher, so
      # page can take these steps and no others.
      module Actions
        NEEDS = {
          "answer" => %i[target text], "reply" => %i[target text], "board_train" => [], "promote" => [],
          "check_in" => %i[target session text]
        }.freeze

        # The program each step runs: the launcher, except a reply, which resumes a Claude session.
        PROGRAMS = { "reply" => "claude" }.freeze

        # The steps that move code: a push and a promotion run only once the page has asked twice.
        CONFIRMS = %w[board_train promote].freeze

        module_function

        # @param action [Object] the step the request names
        # @return [Boolean] whether the board knows the step
        def known?(action) = NEEDS.key?(action)

        # @param action [String] a known step
        # @param fields [Hash{Symbol => String}] the request's fields
        # @param confirm [Boolean] whether the request confirms the step
        # @return [Array<String>] the launcher's arguments for the step
        # @raise [PipelineBoard::Unavailable] when a field is missing or the step is not confirmed
        def argv(action, fields, confirm:)
          missing = NEEDS.fetch(action).reject { |name| fields[name].is_a?(String) }
          raise PipelineBoard::Unavailable, "#{action} needs #{missing.join(", ")}" unless missing.empty?
          raise PipelineBoard::Unavailable, "#{action} runs only with confirm" if CONFIRMS.include?(action) && !confirm

          command(action, fields)
        end

        # @param action [String] a known step
        # @return [String] the program the step runs
        def program(action) = PROGRAMS.fetch(action, "exe/hecks")

        def command(action, fields)
          case action
          when "answer" then ["AgentRun.answer!", "to=#{fields[:target]}", "answer.value=#{fields[:text]}", "--wait"]
          when "reply" then ["-p", "--resume", fields[:resume].to_s, fields[:text]]
          when "board_train" then ["SendTrain.board!", "--confirm"]
          when "promote" then ["PromotionRun.promote!", "lane=stable", "--confirm", "--wait"]
          when "check_in" then ["RedFlag.check_in!", "run.value=#{fields[:target]}", "session.value=#{fields[:session]}",
                                "taking.value=#{fields[:text]}"]
          end
        end
      end
    end
  end
end
