require "hecks"
require "hecks/behaviors"
require_relative "workspace"

module Hecks
  module Composer
    # Runs a workspace's `.behaviors` files as they stand on screen and reports each test as plain
    # data. Like the other composer files it sits on the hecksagon side: it stages the text, calls
    # the behaviors runner and changes nothing on disk.
    module BehaviorRun
      module_function

      # @param dir [String] the workspace directory
      # @param buffers [Hash{String => String}] unsaved text by path relative to `dir`
      # @return [Hash] `files` (`{path:, parse_error:, runs: [{status:, description:, message:}]}`
      #   per behaviors file, paths relative to the workspace, status "pass", "fail" or "error")
      #   and `summary` (`total`, `passed`, `failed`, `errored` and `parse_errors` counts)
      # @raise [Workspace::OutsideWorkspace] if a buffer's path leaves the workspace
      def call(dir:, buffers: {})
        Workspace.stage(dir: dir, buffers: buffers) do |stage|
          files = Hecks::Behaviors.run_all(stage).files.map { |file| report(stage, file) }
          { files: files, summary: tally(files) }
        end
      end

      # @api private
      def report(stage, file)
        {
          path:        relative_path(stage, file.path),
          parse_error: file.parse_error,
          runs:        file.runs.map { |run| run_hash(run) }
        }
      end

      # The file's path inside the staged directory, whether given real or as staged.
      # @api private
      def relative_path(stage, path)
        path.to_s.delete_prefix("#{File.realpath(stage)}/").delete_prefix("#{stage}/")
      end

      # @api private
      def run_hash(run)
        { status: run.status.to_s, description: run.description, message: run.message }
      end

      # @api private
      def tally(files)
        runs = files.flat_map { |file| file[:runs] }
        {
          total:        runs.size,
          passed:       runs.count { |run| run[:status] == "pass" },
          failed:       runs.count { |run| run[:status] == "fail" },
          errored:      runs.count { |run| run[:status] == "error" },
          parse_errors: files.count { |file| file[:parse_error] }
        }
      end
    end
  end
end
