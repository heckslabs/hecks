# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # Several bluebooks as one editor: each aggregate keeps the name its bluebook gave it and is
        # stamped with the bluebook that declares it, so two aggregates of one name in different
        # bluebooks are two aggregates. The stamps exist only when the editor spans more than one
        # bluebook (`chapter`), or when a bluebook's roles are limited (`roles`), so an editor of one
        # open bluebook reads exactly as a bluebook alone does.
        module Composition
          module_function

          # @param bluebooks [Array<Bluebook::Declaration>] the bluebooks, in the order the row names them
          # @param skip [Array<String>] `Name` (in every bluebook) or `Chapter::Name` to leave out
          # @param roles [Hash{String => Array<String>}] the roles each bluebook is limited to
          # @yieldparam aggregate [Bluebook::Aggregate] one aggregate to shape
          # @yieldreturn [Hash{String => Object}] the aggregate as the editor reads it
          # @return [Array<Hash{String => Object}>] the shaped aggregates, bluebook by bluebook
          def aggregates(chapters, skip:, roles:)
            many = chapters.size > 1
            chapters.flat_map do |chapter|
              kept(chapter, skip).map { |agg| stamp(yield(agg), many ? chapter.name : nil, roles[chapter.name]) }
            end
          end

          # @return [Array<Bluebook::Aggregate>] the bluebook's aggregates that are not skipped
          def kept(chapter, skip)
            chapter.aggregates.reject { |agg| skip.intersect?([agg.hecks_name, "#{chapter.name}::#{agg.hecks_name}"]) }
          end

          # @return [Hash{String => Object}] `shaped` with its bluebook and roles after its name
          def stamp(shaped, named, roles)
            extra = { "chapter" => named, "roles" => roles }.compact
            { "name" => shaped["name"], **extra, **shaped.except("name") }
          end
        end
      end
    end
  end
end
