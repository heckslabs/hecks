# frozen_string_literal: true

require "json"
require "tempfile"
require_relative "report"

module Hecks
  module Adapters
    module Codebase
      class SpecFiles
        # Every file in one test-runner process; the JSON formatter says which file each example
        # belongs to, and the runner's own message which file did not load.
        class SharedRun
          LOAD_ERROR = /error occurred while loading (.+?)\.?$/

          # @param tree [Tree] the checkout
          # @param runner [#outcome] runs the test runner on arguments
          def initialize(tree, runner)
            @tree = tree
            @runner = runner
          end

          # @param names [Array<String>] the spec files
          # @param options [Array<String>] the runner's filters, such as `--example x`
          # @param env [Hash{String => String}] variables the specs read
          # @return [Array(Array<Ending>, String)] how each file ended, and what the process printed
          def call(names, options, env)
            Tempfile.create(["spec-files", ".json"]) do |json|
              args = ["--format", "documentation", "--format", "json", "--out", json.path, *options, *names]
              status, printed = @runner.outcome(args, env: env)
              by_file = examples_by_file(json.path)
              endings = names.map { |name| ending(name, by_file.fetch(key(name), [])) }
              blame_load_errors(endings, status, printed)
              [endings, printed]
            end
          end

          private

          def examples_by_file(path)
            JSON.parse(File.read(path)).fetch("examples", []).group_by { |entry| key(entry["file_path"].to_s) }
          rescue JSON::ParserError, Errno::ENOENT
            {}
          end

          # A file as the runner may spell it (relative, absolute, through a symlink), made
          # comparable.
          def key(path)
            full = File.expand_path(path, @tree.root)
            File.exist?(full) ? File.realpath(full) : full
          end

          def ending(name, examples)
            failures = examples.count { |entry| entry["status"] == "failed" }
            Ending.new(name, examples.size, failures, failures.positive?, "")
          end

          # A file that did not load has no examples, and the runner then runs none of the others.
          # The runner names the file; when the run failed with no failed example and no name,
          # every file is blamed.
          def blame_load_errors(endings, status, printed)
            return if status.zero? || endings.any?(&:failed)

            named = loading(printed)
            (named.empty? ? endings : endings.select { |one| named.include?(key(one.file)) }).each { |one| one.failed = true }
          end

          def loading(printed) = printed.scan(LOAD_ERROR).flatten.map { |path| key(path) }
        end
      end
    end
  end
end
