# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Table
        # The values a row takes when its declaration leaves them out: what its source implies for
        # kind, origin and verbs, and what its kind and auth imply for render, cache and indexing.
        module RowDefaults
          module_function

          # @param source [String] the row's source
          # @return [String] `endpoint` for a command or query source, else `page`
          def kind(source) = source.match?(RowBuilder::DERIVED_SOURCE) ? "endpoint" : "page"

          # @param source [String] the row's source
          # @return [String] `domain` for a command or query source, else `website`
          def origin(source) = source.match?(RowBuilder::DERIVED_SOURCE) ? "domain" : "website"

          # Fills every field a row may leave undeclared, in the order each depends on the last.
          #
          # @param row [Row] the row, with its kind, auth, origin and source set
          # @return [void]
          def fill(row)
            fill_flags(row)
            fill_lists(row)
            row.cache ||= default_cache(row)
            row.indexable = indexable_by_default?(row) if row.indexable.nil?
            fill_slots(row)
          end

          def fill_flags(row)
            row.off = false if row.off.nil?
            row.compress = true if row.compress.nil?
            row.cdn = true if row.cdn.nil?
            row.render ||= row.kind == "page" ? "prerender" : "ssr"
          end

          def fill_lists(row)
            row.verbs = list(row.verbs || (row.source.start_with?("command:") ? "POST" : "GET"))
            row.edge_verbs = row.edge_verbs.nil? ? row.verbs : list(row.edge_verbs)
            row.aliases = list(row.aliases)
          end

          def fill_slots(row)
            row.preview ||= "public"
            row.switch ||= ""
            row.footer_order ||= 0 if row.footer_column
            row.admin_order ||= 0 if row.admin_key
          end

          def list(text) = text.to_s.split(",").map(&:strip).reject(&:empty?)

          def default_cache(row)
            return "no_store" if row.auth != "public" || row.kind == "endpoint"

            row.origin == "assets" ? "immutable" : "page"
          end

          def indexable_by_default?(row) = row.kind == "page" && row.auth == "public" && !row.off
        end
      end
    end
  end
end
