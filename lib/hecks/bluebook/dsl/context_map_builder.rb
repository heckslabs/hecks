require_relative "../context_map"
require_relative "../acknowledgements"

module Hecks
  module Bluebook
    module DSL
      # Parses a `.contextmap` file's top-level block into a {Bluebook::ContextMap}: the contexts a
      # system holds and how pairs of them relate, written before the wiring and held against it
      # by `model_check` (ADR 0135).
      class ContextMapBuilder
        # @param name [String, Symbol] the system the map covers
        # @yield the map's body
        # @return [Bluebook::ContextMap] the built map
        # @raise [ArgumentError] on an unknown kind, or a relationship naming an undeclared context
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        def initialize(name)
          @name          = name.to_s
          @contexts      = []
          @relationships = []
          @separate_ways = []
        end

        # Declares a context and, if known, the team that owns it.
        def context(name, team: nil)
          @contexts << ContextMap::Context.new(name: name.to_s, team: team)
        end

        # Declares that `upstream => downstream` relate as `kind`. `published:` lists the upstream
        # events a downstream may depend on, `of:` the names a shared kernel holds in common, and
        # `acknowledges:` the findings about the relationship it allows, each with its reason.
        #
        # @raise [ArgumentError] unless exactly one `"Upstream" => "Downstream"` pair is given
        # @raise [Bluebook::DSL::Malformed] if an acknowledgement names a kind the relationship
        #   cannot carry, or gives no reason
        def relate(as:, published: [], of: [], acknowledges: {}, **pair)
          raise ArgumentError, "relate takes one \"Upstream\" => \"Downstream\" pair" unless pair.size == 1

          upstream, downstream = pair.first
          @relationships << ContextMap::Relationship.new(
            upstream: upstream.to_s, downstream: downstream.to_s, kind: as,
            published: Array(published).map(&:to_s), shared: Array(of).map(&:to_s),
            acknowledged: acknowledged_by("#{upstream} => #{downstream}", acknowledges)
          )
        end

        # Declares two contexts apart: any coupling between them is an error.
        def separate_ways(left, right)
          @separate_ways << [left.to_s, right.to_s]
        end

        def build
          ContextMap.new(name: @name, contexts: @contexts, relationships: @relationships,
                         separate_ways: @separate_ways)
        end

        private

        # @return [Hash{Symbol=>String}] each acknowledged kind with its reason, once all pass
        def acknowledged_by(owner, acknowledges)
          acknowledges.to_h do |finding, reason|
            kind = Acknowledgements.kind!(owner, finding, reason, among: Acknowledgements::RELATIONSHIP_KINDS)
            [kind, reason]
          end
        end
      end
    end
  end
end
