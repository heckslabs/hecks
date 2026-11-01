require "hecks/adapters/driving/cli_runner"
require_relative "index"
require_relative "scan"
require_relative "sources"

module Hecks
  module CommandNames
    # The check that every launcher name a file invokes is one the launcher accepts.
    #
    # A renamed command leaves its old name in gate rows, workflows, specs and docs, and a gate that
    # runs a name the launcher refuses runs nothing. This reads those places for `exe/hecks <name>`
    # and `hecks <name>` and looks each up in the launcher's own name table, once.
    module Check
      # One invocation the launcher would refuse.
      Finding = Struct.new(:path, :line, :text, :problem) do
        # @return [String] `file:line`, the string, the fault and the nearest valid name
        def to_s
          near = problem.nearest ? "; nearest valid name: #{problem.nearest}" : ""
          "#{path}:#{line}: #{text[0, 120]} -- #{problem.text}#{near}"
        end
      end

      module_function

      # @param root [String] the checkout
      # @param scopes [Hash] `CliRunner.name_index`
      # @return [Array<Finding>] every invocation the launcher would refuse, by file then line
      def findings(root:, scopes:)
        index = Index.new(scopes)
        Sources.files(root).flat_map do |path|
          Scan.new(path, File.read(File.join(root, path), encoding: "UTF-8")).calls.filter_map do |call|
            problem = index.problem(call.words)
            Finding.new(path, call.line, call.text, problem) if problem
          end
        end
      end
    end
  end
end
