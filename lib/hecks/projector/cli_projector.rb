require_relative "../naming"
require_relative "cli_projector/claims"
require_relative "cli_projector/command_specs"
require_relative "cli_projector/query_specs"
require_relative "cli_projector/option_specs"
require_relative "cli_projector/usage"
require_relative "cli_projector/listing"
require_relative "cli_projector/command_help"

module Hecks
  module Projector
    # Projects a bluebook as its own command-line surface: the command tree, argument spec
    # and usage text. Nothing executes here; the generic runner (`hecks run`) parses against it.
    #
    # Argument types come from the declared field types, never from guessing at the
    # string: `sequence.value=99` must become 99, and a version "99" must stay a String.
    module CliProjector
      module_function

      # Projects the command and question tables and the usage text. Commands and queries are
      # separate namespaces (a chapter may declare both under one name); ask a query with `ask`.
      #
      # @param bluebook [Bluebook::Chapter] the booted domain to project
      # @param options [Hash{Symbol => Object}] `:program` (default `"hecks run"`) for the usage
      #   text; `:command` and `:ask` select one command's `--help` text; `:names` maps a launcher
      #   name to the command it stands for (`{ "mcp" => "serve_mcp" }`); `:mint_run_keys` makes a
      #   creating command's `run` key optional, since the launcher mints it
      # @return [Hash{Symbol => Object}] `:commands`, `:questions`, `:names` (alias tables) and
      #   `:usage` (pre-rendered help text)
      # @raise [Bluebook::DSL::Malformed] if two commands project to the same command-line name
      def call(bluebook:, options: {})
        commands = {}
        questions = {}

        bluebook.aggregates.each { |aggregate| claim_aggregate(commands, questions, bluebook, aggregate) }
        claim_reports(questions, bluebook)

        mint_run_keys(commands) if options[:mint_run_keys]

        # The display name is the shortest unambiguous one; both spellings are accepted.
        display_names([commands, questions], options[:names])

        { commands: commands, questions: questions,
          names: { command: aliases(commands), question: aliases(questions) },
          usage: usage(bluebook, commands, questions, options) }
      end

      extend Claims
      extend CommandSpecs
      extend QuerySpecs
      extend OptionSpecs
      extend Usage
      extend Listing
      extend CommandHelp
    end
  end
end
