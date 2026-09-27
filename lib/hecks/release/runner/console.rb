module Hecks
  module Release
    class Runner
      # Talks to the person running the release: progress lines, warnings and the
      # y/N questions that come before anything irreversible.
      class Console
        # @param input [IO] where answers are read from
        # @param out [IO] where progress goes
        # @param err [IO] where refusals and failures go
        # @param assume_yes [Boolean] answer every question yes without asking
        def initialize(input:, out:, err:, assume_yes: false)
          @input = input
          @out = out
          @err = err
          @assume_yes = assume_yes
        end

        # Prints a progress line.
        #
        # @param text [String] the line
        # @return [void]
        def say(text)
          @out.puts(text)
        end

        # Prints a refusal or failure line.
        #
        # @param text [String] the line
        # @return [void]
        def warn(text)
          @err.puts(text)
        end

        # Asks a yes/no question, defaulting to no.
        #
        # @param question [String] what will happen if the answer is yes
        # @return [Boolean] true for `y` or `yes`, or always under `assume_yes`; false on anything
        #   else, including a closed input
        def confirm?(question)
          if @assume_yes
            say("#{question} yes (--yes)")
            return true
          end

          @out.print("#{question} [y/N] ")
          @out.flush
          %w[y yes].include?(@input.gets.to_s.strip.downcase)
        end
      end
    end
  end
end
