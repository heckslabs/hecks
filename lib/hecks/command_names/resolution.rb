require "hecks/adapters/driving/cli_runner"

module Hecks
  module CommandNames
    # What is wrong with a typed line.
    Problem = Struct.new(:text, :nearest)

    # One typed word looked up the way the launcher looks it up: every spelling through
    # `canonical_name`, the bang rule of `BangRule`, the neighbours of `Suggestions`.
    class Resolution
      RUNNER = Adapters::Driving::CliRunner

      # The marks a name carries that a plain English word does not.
      NAME_MARKS = /[_.]/

      # @param scope [Hash] one scope of `CliRunner.name_index`
      # @param typed [String] the word, with its `!` if it has one
      # @param asking [Boolean] whether `query` came before it
      def initialize(scope, typed, asking)
        @scope = scope
        @cli = { names: { command: scope["command"], question: scope["question"] } }
        @typed = typed.chomp("!")
        @bang = typed.end_with?("!")
        @asking = asking
        @name = RUNNER.canonical_name(@cli, @typed)
      end

      # @return [Problem, nil] nil when the launcher would run the line
      def problem
        return unknown unless command || question

        bare_command || banged_query || query_of_command
      end

      private

      def command = @scope["command"][@name]

      def question = @scope["question"][@name]

      def bare_command
        return unless command && !@asking && !@bang

        Problem.new("#{@typed} is a command and writes; write it as #{@typed}!", "#{command}!")
      end

      def banged_query
        return unless @bang && !@asking && !command && question

        Problem.new("#{@typed}! is a query and reads; write it without the !", "query #{question}")
      end

      def query_of_command
        return unless @asking && !question

        Problem.new("#{@typed} is a command, not a query", "#{command}!")
      end

      def unknown
        return if plain? && !homed?

        near = RUNNER.near_names(@cli, RUNNER.snake_form(@name), @asking).first
        Problem.new("#{@typed} is not a command or query", near && listed(near))
      end

      # A lone word with no underscore, dot or bang is as likely English as a name.
      def plain? = !@bang && !@typed.match?(NAME_MARKS)

      # Whether the word is the last part of some name, so a launcher once accepted it bare.
      def homed?
        (@cli[:names][:command].keys + @cli[:names][:question].keys).any? { |key| key.split(".").last == @name }
      end

      def listed(near)
        return "#{@scope["command"][near]}!" if @scope["command"][near]

        "query #{@scope["question"][near]}"
      end
    end
  end
end
