# Hecks::AI::IDE::PromptBuilder
#
# Assembles the final prompt sent to Claude by combining user input,
# file context, screenshots, and project context JSON.
#
#   builder = PromptBuilder.new(context_builder, screenshots)
#   builder.build("fix this", file_context: "lib/foo.rb")
#
require "json"

module Hecks
  module AI
    module IDE
      class PromptBuilder
        def initialize(context_builder, screenshots)
          @context_builder = context_builder
          @screenshots = screenshots
        end

        def build(prompt, file_context: nil)
          parts = [prompt]
          parts << "[User is viewing #{file_context} in the IDE]" if file_context
          parts << "[IDE screenshot at #{@screenshots.latest_path} — use Read to view it]" if @screenshots.latest_path
          parts << "[IDE context]\n#{JSON.pretty_generate(@context_builder.build)}"
          parts.join("\n\n")
        end
      end
    end
  end
end
