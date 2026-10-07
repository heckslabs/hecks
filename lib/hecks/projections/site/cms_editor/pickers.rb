# frozen_string_literal: true

require_relative "targets"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # Which attributes name another aggregate's instance, found by the bluebook's own
        # declarations, so the editor offers the instances in place of a text box. In this order:
        # a `<kind>:<slug>` key by its pattern (see `KeyKinds`), each kind that is an aggregate's
        # snake-case name offering that aggregate; a `reference_to` attribute whose target is an
        # editor aggregate; a value object of one text part named `<Stem>Ref`, where `<Stem>` is
        # the type of an editor aggregate's identity or its name; and `<Image|Picture|Photo|Media>
        # Ref` with a picture aggregate, which suggests pictures and accepts any other text. A
        # target is found once: the same chapter's, else the only one of its name; else none.
        module Pickers
          # The stems that name a picture, for the editor's picture aggregate.
          PICTURE_STEMS = %w[Image Picture Photo Media].freeze

          module_function

          # @param aggregates [Array<Hash{String => Object}>] the aggregates as `Schema` shapes them
          # @param media [Hash{String => Object}, nil] the picture aggregate, as `Media` says
          # @return [Array<Hash{String => Object}>] the aggregates, each attribute that names an
          #   instance carrying its `picker`
          def apply(aggregates, media = nil)
            targets = Targets.new(aggregates, media)
            aggregates.map { |agg| annotate(agg, targets) }
          end

          # @return [Hash{String => Object}] `agg` with a picker on each attribute that has one
          def annotate(agg, targets)
            mark = ->(list) { list.map { |attr| with_picker(attr, agg, targets) } }
            agg.merge("attributes" => mark.call(agg["attributes"]), "valueObjects" => objects(agg, mark),
                      "commands" => marked(agg["commands"], mark), "queries" => marked(agg["queries"], mark))
          end

          # @return [Array<Hash>] the commands or queries, the attributes of each marked
          def marked(items, mark) = items.map { |item| item.merge("attributes" => mark.call(item["attributes"])) }

          # @return [Hash{String => Array}] the value objects, the parts of one of several parts
          #   marked; a value object of one part is entered as the attribute that names it
          def objects(agg, mark)
            agg["valueObjects"].transform_values do |parts|
              parts.size == 1 ? parts.map { |part| part.except("keys") } : mark.call(parts)
            end
          end

          # @return [Hash{String => Object}] `attr` with its `picker`, or as it was
          def with_picker(attr, agg, targets)
            picker = picker_for(attr, agg, targets)
            picker ? attr.except("keys").merge("picker" => picker) : attr
          end

          def picker_for(attr, agg, targets)
            return kinds(attr["keys"], agg, targets) if attr["keys"]
            return targets.named(attr["target"], agg) if attr["kind"] == "reference"

            stem = reference_stem(attr, agg)
            stem && (targets.keyed_by(stem, agg) || (targets.pictures if PICTURE_STEMS.include?(stem)))
          end

          # @return [Hash{String => Array}] one entry per kind, with the aggregate it names if any
          def kinds(words, agg, targets)
            { "kinds" => words.map { |word| { "kind" => word, **(targets.kind(word, agg) || {}) } } }
          end

          # @return [String, nil] `Stem` of a `StemRef` value object that has one plain text part
          def reference_stem(attr, agg)
            return nil unless plain_text_object?(attr, agg["valueObjects"][attr["type"]])

            stem = attr["type"].delete_suffix("Ref")
            stem unless stem.empty? || stem == attr["type"]
          end

          # @return [Boolean] whether `attr` is a value object whose one part is a single text
          def plain_text_object?(attr, parts)
            attr["kind"] == "object" && parts&.size == 1 && parts.first["kind"] == "text" && !parts.first["list"]
          end
        end
      end
    end
  end
end
