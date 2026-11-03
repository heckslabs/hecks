# frozen_string_literal: true

require_relative "../../tools"
require_relative "../shard_planner"

module Hecks
  module Tools
    module FuzzSweep
      # Splits the domains of a sweep into `n` shards, so `n` jobs together sweep every domain once.
      #
      # The split is a pure function of the domain list, `n` and the committed cost table: no clock,
      # no discovery order and no run history reach it, so every job computes the same partition.
      # Domains are dealt, dearest first, to whichever shard holds the least cost so far, which
      # keeps the shards near one another in cost; a domain the table does not name costs the
      # table's median, and an absent table costs every domain the same.
      module Shards
        # What `--shard` takes: the shard's number, a slash, and how many shards there are.
        SHARD_WORD = %r{\A([1-9]\d*)/([1-9]\d*)\z}

        # Where the committed cost table is read from, relative to the checkout: one
        # `directory:seconds` line for each domain, `#` lines being notes.
        COST_TABLE = "spec/fuzzing/fuzz_runtime_baseline.log"

        # What a domain costs when no table says: every domain alike.
        FLAT_COST = 1.0

        # A split that left a domain out or put one in two shards.
        class NotAPartition < StandardError; end

        module_function

        # @param word [String, nil] the word after `--shard`
        # @return [Array(Integer, Integer), nil] the shard's number and the shard count, or nil when
        #   the word is not `I/N` with `I` between 1 and `N`; warns what is accepted
        def parse_shard(word)
          match = SHARD_WORD.match(word.to_s)
          return [match[1].to_i, match[2].to_i] if match && match[1].to_i <= match[2].to_i

          warn "unknown --shard #{word.inspect} — use I/N with I from 1 to N, such as 1/2, 2/2 or 3/4"
          nil
        end

        # @param domains [Array<String>] the domain directories, each unique
        # @param shards [Integer] how many shards to split into
        # @param costs [Hash{String => Float}] each domain directory's cost, perhaps lacking some
        # @return [Array<Array<String>>] the domains of each shard, each in the order `domains` has
        def partition(domains, shards, costs = {})
          dealt = ShardPlanner.partition(domains, shards, price_table(domains, costs))
          dealt.map { |members| domains.select { |domain| members.include?(domain) } }
        end

        # @param domains [Array<String>] the domain directories
        # @param number [Integer] the shard wanted, from 1
        # @param shards [Integer] how many shards there are
        # @param costs [Hash{String => Float}] each domain directory's cost
        # @return [Array<String>] the domains that shard sweeps
        def select(domains, number, shards, costs = {}) = partition(domains, shards, costs).fetch(number - 1)

        # The assignment as data: one line for each domain, `I/N<TAB>cost<TAB>directory`, shard by
        # shard. A split that left a domain out or put one in two shards is refused, since a job
        # that reads this list would then trust a sweep that covers less than it says.
        #
        # @param domains [Array<String>] the domain directories
        # @param shards [Integer] how many shards to split into
        # @param costs [Hash{String => Float}] each domain directory's cost
        # @param root [String] the checkout the directories are shown relative to
        # @return [Array<String>] the lines
        # @raise [NotAPartition] when the shards are not a partition of `domains`
        def listing(domains, shards, costs, root)
          split = partition(domains, shards, costs)
          raise NotAPartition, "the shards are not a partition of the domains" unless split.flatten.sort == domains.sort

          price = price_table(domains, costs)
          split.each_with_index.flat_map do |members, index|
            members.map { |domain| row("#{index + 1}/#{shards}", price[domain], domain.delete_prefix("#{root}/")) }
          end
        end

        def row(shard, price, directory) = "#{shard}\t#{price.round(1)}\t#{directory}"

        # Every discoverable domain, or the share of them `--shard I/N` asks for, which a pool
        # starts dearest first so the longest domain is never the last one left running.
        #
        # @param options [Hash] the parsed options: `shard`, perhaps
        # @param root [String] the checkout
        # @return [Array<String>] the domain directories this sweep covers
        def domains_for(options, root)
          domains = Hecks::Corpus.fuzzable_domains(root)
          return domains unless options[:shard]

          number, shards = options[:shard]
          puts "shard #{number}/#{shards}"
          costs = costs_from(root)
          dearest_first(select(domains, number, shards, costs), costs)
        end

        # @param domains [Array<String>] the domain directories
        # @param costs [Hash{String => Float}] each domain directory's cost
        # @return [Array<String>] the same domains, dearest first, ties in path order
        def dearest_first(domains, costs)
          price = price_table(domains, costs)
          domains.sort_by { |domain| [-price[domain], domain] }
        end

        # Prints the listing of every domain of the checkout, and sweeps nothing.
        #
        # @param shards [Integer] how many shards to split into
        # @param root [String] the checkout
        # @return [Integer] 0 once printed
        def print_listing(shards, root)
          puts listing(Hecks::Corpus.fuzzable_domains(root), shards, costs_from(root), root)
          0
        end

        # @param root [String] the checkout
        # @return [Hash{String => Float}] seconds by absolute domain directory, from the committed
        #   table; empty when the table is absent
        def costs_from(root)
          path = File.join(root, COST_TABLE)
          return {} unless File.file?(path)

          File.readlines(path, chomp: true).reject { |line| line.strip.empty? || line.start_with?("#") }
              .to_h { |line| line.split(":", 2).then { |dir, seconds| [File.join(root, dir), Float(seconds)] } }
        end

        # @return [Hash{String => Float}] each domain's cost, a missing one at the table's median
        def price_table(domains, costs) = ShardPlanner.prices(domains, costs, ->(_domain) { FLAT_COST })

        # @return [Array<Float>] each domain's cost, in the order of `domains`
        def prices(domains, costs) = price_table(domains, costs).values_at(*domains)
      end
    end
  end
end
