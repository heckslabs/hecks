# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # What a holder's rules say about how much an attribute may hold: a list's least and most
        # rows (`chapters.size >= 1`, `parts.size <= 12`) and a text's most characters
        # (`summary.to_s.size <= 600`). The rules are the domain's own, so the editor shows the
        # limit it will be held to, and a text that may be long is entered in a writing box.
        #
        # The holder is a value object (its invariants), an aggregate (its invariants) or a command
        # (its `given`s). A rule is read only when it is the whole of the invariant, or the whole
        # of it after an `x.unset? ||` guard on the same part.
        module Limits
          # A list's size compared with a number.
          LIST = /\A(\w+)\.size (<=|>=) (\d+)\z/

          # A text's length bounded above (`to_s.size`, `size` or `length`), maybe after a guard.
          TEXT = /\A(?:(\w+)\.unset\? \|\| )?(\w+)\.(?:to_s\.)?(?:size|length) <= (\d+)\z/

          # A text that may be longer than this many characters is entered in a writing box.
          MULTILINE_FROM = 200

          module_function

          # @param attributes [Array<Hash{String => Object}>] the holder's attributes as `Schema`
          #   shapes them
          # @param rules [Array<#canonical>] the holder's invariants or `given`s
          # @return [Array<Hash{String => Object}>] the attributes, each with `min` and `max` when
          #   it is a list a rule bounds, and `maxLength` (with `multiline` above `MULTILINE_FROM`)
          #   when it is a text a rule bounds
          def apply(attributes, rules)
            texts = rules.map { |rule| rule.canonical.to_s }
            lists = sizes(texts)
            bound = lengths(texts)
            attributes.map { |attr| attr.merge(listed(attr, lists), texted(attr, bound)) }
          end

          # @return [Hash{String => Hash{String => Integer}}] each list's `min` and `max`; where a
          #   holder says several, the tightest wins
          def sizes(texts)
            texts.filter_map { |text| LIST.match(text) }.each_with_object({}) do |found, bounds|
              held = (bounds[found[1]] ||= {})
              kind = found[2] == "<=" ? "max" : "min"
              held[kind] = [held[kind], found[3].to_i].compact.public_send(kind == "max" ? :min : :max)
            end
          end

          # @return [Hash{String => Integer}] each text's most characters
          def lengths(texts)
            texts.filter_map { |text| TEXT.match(text) }
                 .select { |found| found[1].nil? || found[1] == found[2] }
                 .to_h { |found| [found[2], found[3].to_i] }
          end

          def listed(attr, lists)
            found = attr["list"] ? lists[attr["name"]] : nil
            found ? found.reject { |kind, size| kind == "min" && size < 1 } : {}
          end

          def texted(attr, bound)
            most = attr["type"] == "String" && !attr["list"] ? bound[attr["name"]] : nil
            return {} unless most

            { "maxLength" => most, **(most > MULTILINE_FROM ? { "multiline" => true } : {}) }
          end
        end
      end
    end
  end
end
