module Hecks
  class Workshop
    class WebRunner
      # Hecks::Workshop::WebRunner::Evaluator
      #
      # Delegates to CommandParser for safe, eval-free command execution.
      # Input is parsed as a limited command language — only whitelisted
      # Workshop and AggregateHandle methods are callable. No arbitrary
      # Ruby execution.
      #
      #   evaluator = Evaluator.new(runner)
      #   result = evaluator.evaluate("Pizza.attr :name, String")
      #   # => { output: "name attribute added to Pizza", error: nil }
      #
      class Evaluator
        def initialize(runner, web_runner: nil)
          @parser = CommandParser.new(runner, web_runner: web_runner)
        end

        def evaluate(input)
          @parser.execute(input)
        end
      end
    end
  end
end
