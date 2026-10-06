module Hecks
  module Fuzzing
    module Mutation
      # Chooses which sites to try within a budget: every operator gets a turn before any gets a
      # second, each in a seeded shuffle, so a small budget still samples all of them instead of
      # exhausting the first.
      module Selection
        module_function

        # @param sites [Array<Site>] every site found
        # @param budget [Integer] how many to take at most
        # @param seed [Integer] draws the shuffle
        # @param operators [Array<Symbol>, nil] restricts the choice to these operators
        # @return [Array<Site>] the sites to try, repeatable for one seed
        def pick(sites, budget:, seed:, operators: nil)
          sites = sites.select { |site| operators.include?(site.operator) } if operators
          rng = Random.new(seed)
          queues = sites.group_by(&:operator).sort_by { |operator, _| operator.to_s }
                        .map { |_, group| group.shuffle(random: rng) }
          deal(queues, budget)
        end

        # Takes one from each queue in turn until the budget is spent or they are empty.
        def deal(queues, budget)
          taken = []
          taken.concat(queues.filter_map(&:shift)) while taken.size < budget && queues.any?(&:any?)
          taken.first(budget)
        end
      end
    end
  end
end
