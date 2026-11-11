# frozen_string_literal: true

require_relative "../git"

module Hecks
  module Adapters
    class MainIntegration
      # Where a verified commit stands against local main, as three facts a boarding reads: whether
      # main still holds it, whether `origin/main` already carries it, and how many commits main
      # holds above it. It reads and decides nothing.
      class Standing
        # @param repository [Repository] the checkout's repository
        # @param landed [String] the verified commit
        # @param head [String] the commit local main names
        def initialize(repository, landed, head)
          @repository = repository
          @landed = landed
          @head = head
          @git = Git.new
        end

        # @return [Boolean] whether the commit is the head or an ancestor of it
        def held_by_main?
          @landed == @head || @git.ancestor?(@landed, @head, chdir: @repository.checkout)
        end

        # @return [Boolean] whether `origin/main`, as last fetched, already carries the commit
        def carried_by_origin? = !@repository.carried_by(@landed).nil?

        # @return [Integer] the commits main holds above the commit; zero when it is the head
        def newer
          done = @git.capture("rev-list", "--count", "#{@landed}..#{@head}", chdir: @repository.checkout)
          done.ok? ? done.out.to_i : 0
        end

        # @return [Boolean] whether main holds the commit and origin does not yet carry it
        def boardable? = held_by_main? && (@landed == @head || !carried_by_origin?)
      end
    end
  end
end
