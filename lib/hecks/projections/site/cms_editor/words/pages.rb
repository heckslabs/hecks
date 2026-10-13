# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        module Words
          # Reads the `EditorPage` rows into the schema's `pages`: for a page's slug, the addresses a
          # visitor reaches it at and what the site's template does not draw of it. The editor uses the
          # addresses for "View on the site" and for answering "not found" for a page that is hidden,
          # and `undrawn` for the sentence that says what changes will not show yet.
          module Pages
            # A path on the site: one slash first, no whitespace, no placeholder, no query.
            PATH = %r{\A/[^\s?\#\{\}]*\z}

            module_function

            # @param rows [Array<Hash{Symbol => Object}>] the checked `EditorPage` rows
            # @return [Array<Hash{String => Object}>] each page: `slug`, `routes` and `undrawn`
            # @raise [Table::Invalid] naming every row that is declared twice or names a bad address
            def build(rows)
              problems = []
              built = rows.map { |row| shape(row, problems) }
              built.map { |page| page["slug"] }.tally.each do |slug, count|
                problems << "EditorPage #{slug.inspect} is declared twice" if count > 1
              end
              Words.refuse("EditorPage rows", problems)
              built
            end

            # @return [Hash{String => Object}] the page, with each bad address noted in `problems`
            def shape(row, problems)
              routes = row[:route].to_s.split(",").map(&:strip).reject(&:empty?)
              routes.grep_v(PATH).each do |route|
                problems << "EditorPage #{row[:slug]}: route #{route.inspect} is not a path that starts with one slash"
              end
              { "slug" => row[:slug], "routes" => routes, "undrawn" => row[:undrawn] }.compact
            end
          end
        end
      end
    end
  end
end
