# frozen_string_literal: true

require_relative "searching"
require_relative "example_probe"

module Hecks
  module Adapters
    class MainIntegration
      # The search of a red train: the landings the train holds beyond `origin/main`, searched once
      # for each failing example CI named, with that example as the test. The examples are
      # searched in turn until one names a landing that is red while `origin/main` is green; the
      # train that boards after its revert has CI judge the others again. It reads and decides
      # nothing: whether to revert is the domain's rule.
      class TrainSearching
        # The most failing examples one train's search takes, each a search of its own.
        LIMIT = 4

        # @param repository [Repository] the repository the train's landings are in
        # @param runner [#call, nil] stands in for {ExampleProbe}: given a copy's directory and
        #   one failing example, it returns, or raises `ConsoleCapture::Failure` when it is red
        def initialize(repository, runner: nil)
          @repository = repository
          @runner = runner
        end

        # @param landed [String] the train's head
        # @param since [String] the commit `origin/main` is at
        # @param examples [Array<String>] the failing examples, each `spec/x_spec.rb:12`
        # @return [Hash{Symbol => Object}] the facts of {Bisecting#facts} for the example that
        #   names a landing; else for one no landing explains; else for one red at `since` too
        def call(landed, since, examples)
          answers = []
          examples.first(LIMIT).each do |example|
            answers << search(example, landed, since)
            break if blamed?(answers.last)
          end
          answers.find { |facts| blamed?(facts) } || answers.find { |facts| !facts[:base_red] } || answers.first
        end

        private

        def search(example, landed, since)
          runner = @runner || ExampleProbe.new(@repository.checkout, landed)
          facts = Searching.new(@repository, failing: [example], runner: runner).call(landed, since)
          facts.merge(reason: [example, facts[:reason]].compact.join(": "))
        end

        def blamed?(facts) = !facts[:culprit].to_s.empty? && !facts[:base_red]
      end
    end
  end
end
