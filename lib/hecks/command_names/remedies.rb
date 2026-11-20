require_relative "check"
require_relative "index"
require_relative "remedy_scan"

module Hecks
  module CommandNames
    # The check that every remedy a refusal names is a command the launcher runs (ADR 0190 point 7).
    #
    # A refusal tells its reader what to run next. When the command it names is renamed or retired,
    # the refusal points at nothing; this reads Ruby refusals and the Rust host's refusal strings
    # (`RemedyScan`) and holds each remedy against the launcher's own name table. A remedy must also
    # name a command a person or an agent runs, never one whose audience is only `record`.
    module Remedies
      # Globs, relative to the checkout, of the files whose refusals are read.
      GLOBS = %w[lib/**/*.rb rust/host/src/**/*.rs].freeze

      module_function

      # @param root [String] the checkout
      # @param scopes [Hash] `CliRunner.name_index`
      # @param record_only [Array<String>] commands as the launcher lists them whose only
      #   audience is `record` (`RecordOnly.names`)
      # @return [Array<Check::Finding>] every remedy that names no runnable command, by file then
      #   line
      def findings(root:, scopes:, record_only: [])
        index = Index.new(scopes)
        files(root).flat_map do |path|
          RemedyScan.new(path, File.read(File.join(root, path), encoding: "UTF-8")).remedies.filter_map do |call|
            problem = index.problem(call.words) || record_problem(index.command_of(call.words), record_only)
            Check::Finding.new(path, call.line, call.text, problem) if problem
          end
        end
      end

      # @return [Array<String>] the files read, relative to `root`, sorted
      def files(root)
        paths = GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) }.select { |path| File.file?(path) }
        Sources.relative(root, paths)
      end

      # @return [Problem, nil] the fault of a remedy that names a record-only command
      def record_problem(command, record_only)
        return unless command && record_only.include?(command)

        Problem.new("#{command}! is a record's own command; a refusal names one a person or an agent runs", nil)
      end
    end
  end
end
