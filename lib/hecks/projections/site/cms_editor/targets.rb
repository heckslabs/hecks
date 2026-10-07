# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The aggregates an attribute can name, found among the aggregates of one editor, and what
        # a picker needs to know about each: its key, the attribute that labels it and the query
        # that lists the ones to offer.
        class Targets
          # The attribute names that label an instance, in the order they are tried; an aggregate
          # with none is labelled by its identity.
          LABELS = %w[title name label].freeze

          # The zero-argument queries that list what is on offer, tried in this order: ones that
          # list everything, then the one that lists what is in use.
          LISTINGS = %w[all list listing active].freeze

          # @param aggregates [Array<Hash{String => Object}>] the aggregates as `Schema` shapes them
          # @param media [Hash{String => Object}, nil] the picture aggregate, as `Media` says
          def initialize(aggregates, media = nil)
            @aggregates = aggregates
            @media = media
          end

          # @return [Hash{String => Object}, nil] the aggregate named `name`, as a picker names it
          def named(name, from)
            pick(@aggregates.select { |agg| agg["name"] == name }, from)
          end

          # @return [Hash{String => Object}, nil] the aggregate whose identity is of type `stem`, or
          #   that is named `stem`, as a picker names it
          def keyed_by(stem, from)
            pick(@aggregates.select { |agg| identity_type(agg) == stem }, from) || named(stem, from)
          end

          # @return [Hash{String => Object}, nil] the aggregate that is `word` in snake case
          def kind(word, from)
            pick(@aggregates.select { |agg| snake(agg["name"]) == word }, from)
          end

          # @return [Hash{String => Object}, nil] the picture aggregate, which offers keys and
          #   accepts any other text as well, since a picture may be named by an address
          def pictures
            return nil unless @media

            agg = @media["definition"] || @aggregates.find { |candidate| candidate["name"] == @media["aggregate"] }
            return nil unless agg

            described = describe(agg, agg["chapter"] || @media["domain"], @media["listing"])
            described.merge("label" => @media.dig("fields", "alt", "name"), "strict" => false)
          end

          private

          def pick(found, from)
            own = found.select { |agg| agg["chapter"] == from["chapter"] }
            chosen = own.first || (found.first if found.size == 1)
            chosen && describe(chosen, chosen["chapter"], listing(chosen)).merge("strict" => true)
          end

          def describe(agg, chapter, listing)
            { "target" => agg["name"], "chapter" => chapter, "key" => agg["identity"], "label" => label(agg),
              "listing" => listing }.compact
          end

          def identity_type(agg)
            agg["attributes"].find { |attr| attr["name"] == agg["identity"] }&.fetch("type", nil)
          end

          def label(agg)
            plain = agg["attributes"].reject { |attr| attr["list"] || attr["widget"] == "body" }.map { |attr| attr["name"] }
            LABELS.find { |name| plain.include?(name) } || agg["identity"]
          end

          def listing(agg)
            named = agg["queries"].select { |query| query["attributes"].empty? }.map { |query| query["name"] }
            LISTINGS.filter_map { |word| named.find { |name| name.downcase == word } }.first
          end

          def snake(name) = name.gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase
        end
      end
    end
  end
end
