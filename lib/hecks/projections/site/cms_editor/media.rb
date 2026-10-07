# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The aggregate that registers pictures, found by shape in the schema the editor reads.
        #
        # It is an aggregate with a creating command whose attributes are the aggregate's identity
        # (the key), an alt text and a mime type, and optionally a width and a height; every other
        # attribute of that command must be optional, because an upload cannot fill it. Neither the
        # aggregate's name nor the command's decides it; the attribute names are the vocabulary, the
        # way `blocks`, `kind` and `spans` are for a document body. An attribute is a plain value or
        # a value object whose first part is a plain value; the editor sends a value the same way.
        #
        # The domain keeps the picture's record, never its bytes.
        module Media
          # The attribute names that carry each part of a picture's record besides its key.
          ROLES = { "alt" => %w[alt alt_text], "mime" => %w[mime_type mime content_type],
                    "width" => %w[width], "height" => %w[height] }.freeze

          # The parts every picture's registration must take.
          REQUIRED = %w[key alt mime].freeze

          module_function

          # @param aggregates [Array<Hash{String => Object}>] the aggregates, as `Schema` reads them
          # @return [Hash{String => Object}, nil] the aggregate and command that register a
          #   picture, each part's attribute and the query that lists the pictures; nil when no
          #   aggregate has the shape
          def read(aggregates)
            aggregates.each do |agg|
              agg["commands"].select { |command| command["creates"] }.each do |command|
                found = fields(agg, command)
                return describe(agg, command, found) if found
              end
            end
            nil
          end

          # @return [Hash{String => Hash}, nil] each part's attribute and how its value is sent, or
          #   nil when the command is not a picture's registration
          def fields(agg, command)
            chosen = parts(agg, command["attributes"])
            return nil unless REQUIRED.all? { |role| chosen.key?(role) } && others_optional?(command, chosen)

            wrapped = chosen.transform_values { |attr| wrap(agg, attr) }
            return nil if wrapped.value?(false)

            chosen.to_h { |role, attr| [role, { "name" => attr["name"], "wrap" => wrapped.fetch(role) }] }
          end

          # @return [Boolean] whether every attribute that is not a part of the record is optional
          def others_optional?(command, chosen)
            (command["attributes"] - chosen.values).all? { |attr| attr["optional"] }
          end

          # @return [Hash{String => Hash}] each part of the record to the attribute that carries it
          def parts(agg, attrs)
            found = { "key" => attrs.find { |attr| attr["name"] == agg["identity"] } }
            ROLES.each { |role, names| found[role] = attrs.find { |attr| names.include?(attr["name"]) } }
            found.compact
          end

          # @return [String, nil, false] the part a value object's value is sent in, nil for a
          #   plain value, false for an attribute an upload cannot fill
          def wrap(agg, attr)
            return false if attr["list"] || attr["kind"] == "reference"
            return nil unless attr["kind"] == "object"

            first = agg["valueObjects"].fetch(attr["type"], []).first
            first && first["kind"] != "object" && !first["list"] ? first["name"] : false
          end

          # @return [Hash{String => Object}] the picture aggregate as the editor's schema names it
          def describe(agg, command, found)
            listing = agg["queries"].find { |query| query["attributes"].empty? }
            { "aggregate" => agg["name"], "command" => command["name"], "fields" => found,
              "listing" => listing && listing["name"] }
          end
        end
      end
    end
  end
end
