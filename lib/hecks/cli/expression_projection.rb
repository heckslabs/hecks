# frozen_string_literal: true

require_relative "../projection_files"

module Hecks
  module CLI
    # The command behind `hecks project_expression_tables`: projects the expression machinery's
    # operator and normalisation tables from the grammar chapter into
    # `lib/hecks/bluebook/expression/projection.json`.
    #
    # It never redirects with `>`: the shell would truncate the file the framework requires at
    # boot. The default mode replaces the file atomically, and it refuses a projection that drops
    # a self-bearing operator (one the chapter's own `status != "retired"` givens evaluate
    # through), since that would wedge every later boot. Recover a broken file with
    # `git checkout -- lib/hecks/bluebook/expression/projection.json`.
    module ExpressionProjection
      module_function

      # Rewrites the projection file, or with `--stdout` prints it instead.
      #
      # @param argv [Array<String>] `--stdout` for the diff mode
      # @param out [IO] where the result goes
      # @return [Integer] the exit status, 0 once written or printed
      # @raise [SystemExit] with the refusal when the projection drops a self-bearing operator
      def call(argv, out: $stdout)
        result = begin
          Hecks::ProjectionFiles.build(:expression_tables)
        rescue Hecks::ProjectionFiles::Refused => e
          abort e.message
        end

        if argv.include?("--stdout")
          out.print result.content.values.first
        else
          out.puts Hecks::ProjectionFiles.write(:expression_tables)
        end
        0
      end
    end
  end
end
