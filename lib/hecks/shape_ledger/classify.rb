# frozen_string_literal: true

require "digest"
require_relative "../ports/persistence/plugins/era/storage_shape"
require_relative "../ports/persistence/plugins/era/translation/scaffold"
require_relative "../ports/persistence/plugins/era/translation/implicit_edge"

module Hecks
  module ShapeLedger
    # Whether a bluebook's move from the shape the ledger holds only adds. The gate and the release
    # mint both ask it, so the two cannot disagree: it reads the held projection against the current
    # bluebook through the same `Translation::ImplicitEdge.qualifies?` the mint decision uses.
    #
    # A held entry with no projection, or one whose projection does not hash to the entry's hash,
    # cannot be read, so nothing it holds is proved additive.
    class Classify
      # @param registry [Runtime::Registry] the loaded bluebooks
      # @param projections [Hash{String => Hash, nil}] each held projection by bluebook name
      # @return [Classify]
      def self.judge(registry, projections) = new(registry.bluebooks, projections)

      # @param bluebooks [Hash{String => Object}] the current bluebooks by name
      # @param projections [Hash{String => Hash, nil}] each held projection by bluebook name
      def initialize(bluebooks, projections)
        @bluebooks = bluebooks
        @projections = projections
      end

      # @param name [String] a bluebook's name
      # @return [Boolean] whether the move from the held projection to the current one only adds
      def additive?(name)
        held = @projections[name]
        return false unless held

        view = Runtime::ProjectedBluebook.new(held)
        Translation::ImplicitEdge.qualifies?(Translation::Scaffold.diff(view, @bluebooks.fetch(name)), view,
                                             @bluebooks.fetch(name))
      end

      # @param projection [Hash] a held projection
      # @return [String] the hash a projection's canonical text holds
      def self.hash_of(projection) = Digest::SHA256.hexdigest(JSON.generate(projection))
    end
  end
end
