# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The records that belong to one record, found by the keys they carry. Aggregate `B` is
        # related to `A` when `B`'s identity is a `<kind>:<slug>` key (see `KeyKinds`) whose
        # kinds include `A`'s snake-case name, so `post:first-light` keys the `B` of the `Post`
        # `first-light`.
        #
        # The rule reads the declared pattern and what the kind resolves to (see `Pickers`),
        # never a name. A `B` is shown by its shape: a **document** (a rich-text body), a
        # **gallery** (a list that names pictures) or **metadata** (anything else). Its creating
        # command is the first that takes the identity; its editing command is the draft-saving
        # command of a document that keeps drafts (see `Drafts`), else the first command on an
        # existing record that is neither a lifecycle move nor destructive and takes the body or
        # the pictures.
        module Relations
          module_function

          # @param aggregates [Array<Hash{String => Object}>] the aggregates as `Pickers` leaves
          #   them
          # @param media [Hash{String => Object}, nil] the picture aggregate, as `Media` says
          # @return [Array<Hash{String => Object}>] each aggregate, carrying `related` when other
          #   aggregates are keyed by it
          def apply(aggregates, media = nil)
            aggregates.map do |agg|
              found = aggregates.reject { |other| other.equal?(agg) }.filter_map { |other| relation(other, agg, media) }
              found.empty? ? agg : agg.merge("related" => found)
            end
          end

          # @return [Hash{String => Object}, nil] how `other` is related to `agg`, or nil when it
          #   is not
          def relation(other, agg, media)
            key = other["attributes"].find { |attr| attr["name"] == other["identity"] }
            return nil unless key && keyed_by?(key, agg)

            shape, field = shape_of(other, media)
            { "aggregate" => other["name"], "chapter" => other["chapter"], "field" => key["name"], "shape" => shape,
              "create" => creating(other, key), "edit" => editing(other, field) }.compact
          end

          # @return [Boolean] whether `key` is declared a key of `<agg's snake name>:<slug>`
          def keyed_by?(key, agg)
            (key.dig("picker", "kinds") || []).any? { |kind| kind["target"] == agg["name"] && kind["chapter"] == agg["chapter"] }
          end

          # @return [Array(String, String)] the shape, and the attribute that gives it
          def shape_of(other, media)
            body = other["attributes"].find { |attr| attr["widget"] == "body" && !attr["list"] }
            return ["document", body["name"]] if body

            pictures = pictures_of(other, media)
            pictures ? ["gallery", pictures["name"]] : ["metadata", nil]
          end

          # @return [Hash{String => Object}, nil] the list attribute that names pictures
          def pictures_of(other, media)
            return nil unless media

            other["attributes"].find { |attr| attr["list"] && attr.dig("picker", "target") == media["aggregate"] }
          end

          # @return [String, nil] the first creating command that takes the identity
          def creating(other, key)
            other["commands"].find do |command|
              command["creates"] && command["attributes"].any? do |attr|
                attr["name"] == key["name"]
              end
            end&.fetch("name")
          end

          # @return [String, nil] the command that changes the record's body, pictures or fields
          def editing(other, field)
            return other.dig("drafts", "save") if other["drafts"] && field == other.dig("drafts", "live")

            moves = (other.dig("lifecycle", "transitions") || []).map { |move| move["verb"] }
            other["commands"].find { |command| edits?(command, field, moves) }&.fetch("name")
          end

          def edits?(command, field, moves)
            names = command["attributes"].map { |attr| attr["name"] }
            !command["creates"] && !command["destructive"] && !moves.include?(command["name"]) &&
              !names.empty? && (field.nil? || names.include?(field))
          end
        end
      end
    end
  end
end
