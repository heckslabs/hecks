# frozen_string_literal: true

require_relative "spec_probe"
require_relative "example_probe"
require_relative "failure_log"

module Hecks
  module Adapters
    class MainIntegration
      # One probe of the search for the first bad merge: the failure of the failed verification,
      # run in a clean copy of a merge or of its first parent. A probe tests the failure itself,
      # not the specs the merge's own paths touch. It runs outside any verification's copy, one
      # after another, so the copy's turn (`CopyLock`) is free.
      class MergeProbe
        # Runs the failing spec files whole until a red run names a failing example, and from then
        # on that example alone, one launcher call in the copy. A copy that does not hold the
        # example's file runs nothing and is green: the example did not exist there.
        class OneExample
          # The first failing example a red run of whole files names: its file and description.
          NAMED = %r{(spec/[\w/.-]*_spec\.rb)(?::\d+)? # (.+?)(?=, \./|$)}

          # @param whole [#call] runs spec files whole in a copy, raising when one is red
          # @param shell [#capture] runs the launcher: `capture(*argv, env:, chdir:)`
          def initialize(whole: SpecProbe.new, shell: ImpactedCheck::Launched.new)
            @whole = whole
            @shell = shell
          end

          # @param directory [String] the clean copy
          # @param files [Array<String>] the spec files the failed verification named
          # @return [void]
          # @raise [ConsoleCapture::Failure] naming the failing spec and example
          def call(directory, files)
            return alone(directory, *@named) if @named

            @whole.call(directory, files)
          rescue ConsoleCapture::Failure => e
            @named ||= e.message.match(NAMED)&.captures
            raise
          end

          private

          def alone(directory, file, described)
            return unless File.exist?(File.join(directory, file))

            argv = [*ExampleProbe::LAUNCHER, "file.value=#{file}", "example.value=#{described}", "--wait"]
            result = @shell.capture(*argv, env: {}, chdir: directory)
            said = [GitShallowCheck::ImpactedBatch.said(result), result.err].join("\n").strip
            return if result.ok? && !said.match?(ExampleProbe::FAILURES)

            raise ConsoleCapture::Failure, "failing spec: #{file}\n  1) #{described}\n#{said[-ExampleProbe::KEPT..] || said}"
          end
        end

        # @param repository [Repository] the repository the merges are in
        # @param failing [Array<String>] the spec files the failed verification named, or the
        #   one failing example of a red train
        # @param runner [#call, nil] stands in for {OneExample}: given the copy's directory and
        #   what is failing, it returns, or raises `ConsoleCapture::Failure` when it is red
        def initialize(repository, failing:, runner: nil)
          @repository = repository
          @failing = failing
          @runner = runner || OneExample.new
        end

        # @param merge [Hash] `sha:` of a landing
        # @return [Array(Boolean, Hash)] whether the failure is green at the merge, and the
        #   failing spec and example it printed when it is not
        def call(merge) = at(merge[:sha])

        # @param merge [Hash] `sha:` of a landing
        # @return [Array(Boolean, Hash)] as {#call}, at the merge's first parent; green when it
        #   has none
        def before(merge)
          parent = @repository.first_parent(merge[:sha])
          parent ? at(parent) : [true, nil]
        end

        # @param commit [String] a commit that holds none of the merges, as the last verified one
        # @return [Boolean] whether the failure is red at the commit: red there too means no
        #   merge of the range is to blame
        def red_at?(commit) = !at(commit).first

        private

        def at(commit)
          @repository.clean_copy(commit) { |directory| run(directory) }
        end

        def run(directory)
          @runner.call(directory, @failing)
          [true, nil]
        rescue ConsoleCapture::Failure => e
          [false, finding(e.message)]
        end

        def finding(message)
          { spec: FailureLog.specs(message).first || @failing.first, example: FailureLog.finding(message)[:example] }.compact
        end
      end
    end
  end
end
