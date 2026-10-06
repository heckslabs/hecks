# frozen_string_literal: true

require "pathname"
require_relative "../../projector"
require_relative "root_rows"
require_relative "payload/model"
require_relative "payload/specs"
require_relative "payload/fields"
require_relative "payload/lifecycle"

module Hecks
  module Projections
    module Site
      # What the content system needs to drive a domain's aggregates, from the domain itself: the
      # lifecycle module, a spec per aggregate (its input, its wire form, its lifecycle edges and
      # the
      # command that creates it) and the Payload field definitions with the readers that turn a
      # saved
      # document back into an input.
      #
      # A `Payload` row names the domain, its chapter and where the files go; `PayloadField` rows
      # say what
      # the editor needs that an attribute's shape cannot (a date picker, a choice list, an upload,
      # a
      # relation). The domain stays free of the content system: it is read, never annotated.
      module PayloadDriver
        extend Projector::Target

        projects_as :payload_driver, emits: :files

        # The `Payload` row.
        PAYLOAD = RootRows.new("Payload",
                               fields:   { domain: String, chapter: String, out: String, hecks: String, helpers: String,
skip: String },
                               required: %i[domain chapter],
                               defaults: { out: "cms/src/generated", hecks: "cms/src/driver/hecks",
                                           helpers: "cms/src/collections/hooks/content", skip: "" })

        # A `PayloadField` row: what the editor needs for one attribute (or `attribute.part` of a
        # composite).
        FIELD = RootRows.new("PayloadField",
                             fields: { aggregate: String, attribute: String, field: String, kind: String, options: String,
                                       relation: String, via: String, label: String, description: String,
                                       required: [TrueClass, FalseClass],
                                       default: String },
                             required: %i[aggregate attribute], many: true)

        module_function

        # @param bluebook [Bluebook::Chapter] the chapter that declares the route table and the rows
        # @param options [Hash{Symbol => Object}] `:domain_chapter` the domain's chapter, or nil
        # @return [Hash{String => String}] each file's path relative to the project root to its
        #   text;
        #   empty when the project declares no `Payload` row
        # @raise [Table::Invalid] when a row is refused
        # @raise [ArgumentError] when an aggregate cannot be driven or a row names what is not there
        def call(bluebook:, options: {})
          row = PAYLOAD.read(bluebook).first
          return {} unless row

          chapter = options.fetch(:domain_chapter)
          aggregates = Payload::Model.read(chapter, skip: row[:skip].split(",").map(&:strip))
          raise ArgumentError, "the #{chapter.name} chapter has no aggregate with a lifecycle to drive" if aggregates.empty?

          files(row, aggregates, FIELD.read(bluebook))
        end

        def files(row, aggregates, rows)
          out = row[:out]
          roles = aggregates.map(&:role).uniq
          if roles.size > 1
            raise ArgumentError,
                  "the driven aggregates' commands declare roles #{roles.inspect}; the driver acts as one"
          end

          from_driver = ->(path) { relative(path, "#{out}/driver") }
          from_collections = ->(path) { relative(path, "#{out}/collections") }
          { "#{out}/driver/lifecycle.ts"   => Payload::Lifecycle.render(role: roles.first, hecks: from_driver.call(row[:hecks])),
            "#{out}/driver/specs.ts"       => Payload::Specs.render(aggregates, lifecycle: "./lifecycle",
                                                                                hecks:     from_driver.call(row[:hecks])),
            "#{out}/collections/fields.ts" => Payload::Fields.render(aggregates, rows: rows, specs: "../driver/specs",
                                                                     helpers: from_collections.call(row[:helpers])) }
        end

        # @return [String] `path` as an import from `dir`, both relative to the project root
        def relative(path, dir)
          target = Pathname.new(path).relative_path_from(Pathname.new(dir)).to_s
          target.start_with?(".") ? target : "./#{target}"
        end
      end
    end
  end
end
