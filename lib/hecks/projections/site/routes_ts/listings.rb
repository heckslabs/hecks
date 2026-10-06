# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module RoutesTs
        # The lists `routes.ts` derives from the rows for search engines and the content system:
        # the sitemap and robots paths, and the content-system sources that name a page.
        module Listings
          module_function

          def search(rows)
            <<~TS.chomp
              // The paths a sitemap lists: indexable pages with no parameter. A collection's pages are listed
              // from its entries, through `collectionPages`.
              export const SITEMAP_PATHS = #{RoutesTs.literal(sitemap_paths(rows))} as const;

              // The routes a search engine is kept away from: every route that is not indexable.
              export const NOT_FOR_SEARCH = #{RoutesTs.literal(hidden_paths(rows))} as const;

              // robots.txt `Disallow` prefixes: each non-public route up to its first parameter.
              export const ROBOTS_DISALLOW = #{RoutesTs.literal(robots(RoutesTs.live(rows)))} as const;
            TS
          end

          def sitemap_paths(rows)
            RoutesTs.live(rows).select { |row| row.indexable && !row.path.match?(/[:*]/) }.map(&:path).sort
          end

          def hidden_paths(rows)
            hidden = rows.reject { |row| row.indexable || row.path == RoutesTs::CATCH_ALL }
            hidden.flat_map { |row| [row.path, *row.aliases] }.sort
          end

          def robots(rows)
            prefixes = rows.reject { |row| row.auth == "public" }.map { |row| robots_prefix(row.path) }
            prefixes = (prefixes + ["#{RoutesTs::PREVIEW_PREFIX}/"]).uniq.sort
            prefixes.reject { |prefix| prefixes.any? { |other| other != prefix && prefix.start_with?(other) } }
          end

          def robots_prefix(path)
            head = path.split("/").take_while { |part| !part.match?(/\A[:*]/) }.join("/")
            head == path ? path : "#{head}/"
          end

          def sources(rows)
            <<~TS.chomp
              // A CMS global's slug to the page that shows it.
              export const globalPages = #{RoutesTs.literal(sourced(rows, "global:", &:path))} as const;

              // A CMS collection's name to the page that shows one of its entries, and whether the sitemap lists them.
              export const collectionPages = #{RoutesTs.literal(collection_pages(rows))} as const;

              const PREVIEWS: Readonly<Record<string, { readonly path: string; readonly draft: boolean }>> = #{RoutesTs.literal(previews(rows))};
            TS
          end

          def collection_pages(rows)
            sourced(rows, "collection:") { |row| { path: row.path, indexable: row.indexable } }
          end

          def previews(rows)
            rows.select { |row| row.source.match?(/\A(global|collection):/) }
                .to_h { |row| [row.source, { path: row.path, draft: row.preview == "draft" }] }.sort.to_h
          end

          def sourced(rows, prefix)
            rows.select { |row| row.source.start_with?(prefix) }
                .to_h { |row| [row.source.delete_prefix(prefix), yield(row)] }.sort.to_h
          end
        end
      end
    end
  end
end
