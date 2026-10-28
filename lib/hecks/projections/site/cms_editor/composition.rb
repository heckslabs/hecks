# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # Several bluebooks as one editor: each aggregate keeps the name its bluebook gave it and is
        # stamped with the bluebook that declares it, so two aggregates of one name in different
        # bluebooks are two aggregates. The stamps exist only when the editor spans more than one
        # bluebook (`bluebook`), or when a bluebook's roles are limited (`roles`), so an editor of
        # one
        # open bluebook reads exactly as a bluebook alone does.
        module Composition
          module_function

          # @param bluebooks [Array<Bluebook::Declaration>] the bluebooks, in the order the row
          #   names them
          # @param skip [Array<String>] `Name` (in every bluebook) or `Bluebook::Name` to leave out
          # @param roles [Hash{String => Array<String>}] the roles each bluebook is limited to
          # @yieldparam aggregate [Bluebook::Aggregate] one aggregate to shape
          # @yieldreturn [Hash{String => Object}] the aggregate as the editor reads it
          # @return [Array<Hash{String => Object}>] the shaped aggregates, bluebook by bluebook
          def aggregates(declarations, skip:, roles:)
            many = declarations.size > 1
            declarations.flat_map do |declaration|
              kept(declaration, skip).map { |agg| stamp(yield(agg), many ? declaration.name : nil, roles[declaration.name]) }
            end
          end

          # @return [Array<Bluebook::Aggregate>] the bluebook's aggregates that are not skipped
          def kept(declaration, skip)
            declaration.aggregates.reject { |agg| skip.intersect?([agg.hecks_name, "#{declaration.name}::#{agg.hecks_name}"]) }
          end

          # @return [Hash{String => Object}] `shaped` with its bluebook and roles after its name
          def stamp(shaped, named, roles)
            extra = { "bluebook" => named, "roles" => roles }.compact
            { "name" => shaped["name"], **extra, **shaped.except("name") }
          end
        end
      end
    end
  end
end
