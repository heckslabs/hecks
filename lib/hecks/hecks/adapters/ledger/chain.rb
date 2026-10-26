# frozen_string_literal: true

require "digest"
require "json"

module Hecks
  module Adapters
    class Ledger
      # The hash chain over a journal's entries: each digest takes the digest before it, so
      # changing, dropping or reordering an entry changes every digest after it.
      module Chain
        # The digest a chain starts from: sixty-four zeros.
        GENESIS = ("0" * 64).freeze

        module_function

        # The digest after one entry.
        #
        # Every field is length-prefixed, so no two entries pack to the same bytes.
        #
        # @param previous [String] the digest before this entry
        # @param aggregate [Bluebook::Aggregate] the aggregate whose state codec encodes the entry
        # @param entry [Ports::Persistence::Entry] the journal entry
        # @return [String] the next digest, lowercase hexadecimal
        def step(previous, aggregate, entry)
          hasher = Digest::SHA256.new
          hasher << previous
          fields(aggregate, entry).each do |field|
            hasher << [field.bytesize].pack("Q>")
            hasher << field
          end
          hasher.hexdigest
        end

        # The digest after a run of entries.
        #
        # @param seed [String] the digest before the first entry
        # @param aggregate [Bluebook::Aggregate] the aggregate the entries belong to
        # @param entries [Array<Ports::Persistence::Entry>] the entries, in append order
        # @return [String] the last digest, or `seed` when there are none
        def fold(seed, aggregate, entries)
          entries.reduce(seed) { |digest, entry| step(digest, aggregate, entry) }
        end

        # One digest for several journals' sealed points, independent of their order.
        #
        # @param points [Array<Hash>] each with `name:`, `through:` and the digest under `key`
        # @param key [Symbol] which digest of each point to take: `:head` or `:previous`
        # @return [String] lowercase hexadecimal
        def summary(points, key)
          lines = points.sort_by { |point| point[:name] }.map { |point| "#{point[:name]}:#{point[:through]}:#{point[key]}" }
          Digest::SHA256.hexdigest(lines.join("\n"))
        end

        # What an entry contributes to its digest, as text.
        def fields(aggregate, entry)
          state = entry.state && Ports::Persistence::StateCodec.encode(aggregate, entry.state)
          [entry.operation, entry.id.to_s, JSON.generate(state), JSON.generate(entry.mirrors)]
        end
      end
    end
  end
end
