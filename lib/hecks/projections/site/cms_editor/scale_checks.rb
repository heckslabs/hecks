# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # What the `Editor` row's settings for many bluebooks and long lists must satisfy: bluebooks
        # named once each, roles given for a bluebook the editor edits, and a page size a list can
        # hold. A bluebook's name is part of an address, so it cannot be spelled as one of the
        # editor's own paths.
        module ScaleChecks
          # The most instances a list may show to a page.
          MAX_PAGE = 1000

          # A whole number from 1, of at most four digits: a page size.
          PAGE_COUNT = /\A[1-9]\d{0,3}\z/

          # The first segments of the editor's own addresses, which no bluebook may be named.
          RESERVED = %w[assets media logout api scheduled].freeze

          module_function

          # @param row [Hash{Symbol => String}] the row, defaults filled
          # @return [Array<String>] every problem with `bluebook`, `declaration_roles` and
          #   `page_size`
          def problems(row)
            declarations = row[:bluebook].split(",").map(&:strip)
            [*bluebook_problems(declarations), *role_problems(row[:bluebook_roles], declarations),
             *page_size_problems(row[:page_size])]
          end

          # @return [Array<String>] the problems with an empty, repeated or reserved bluebook name
          def bluebook_problems(declarations)
            found = []
            found << "bluebook names nothing" if declarations.reject(&:empty?).empty?
            repeated = declarations.find { |name| declarations.count(name) > 1 }
            found << "bluebook names #{repeated.inspect} twice" if repeated
            [*found, *reserved_problems(declarations)]
          end

          # @return [Array<String>] a problem for each bluebook spelled as an address of the
          #   editor's
          def reserved_problems(declarations)
            return [] if declarations.size < 2

            (declarations & RESERVED).map do |name|
              "bluebook #{name.inspect} is the first part of an address the editor serves; name it another way"
            end
          end

          # @return [Array<String>] the problems with `Bluebook=Role,Role;Bluebook=Role` entries
          def role_problems(text, declarations)
            entries = text.split(";")
            entries.map(&:strip).reject(&:empty?).flat_map do |entry|
              name, roles = entry.split("=", 2)
              next ["bluebook_roles #{entry.inspect} must read Bluebook=Role,Role"] if roles.to_s.strip.empty?
              next [] if declarations.include?(name.strip)

              ["bluebook_roles names #{name.strip.inspect}, which is not a bluebook of this editor"]
            end
          end

          # @return [Array<String>] the problem with a page size that is not a whole 1 to 1000
          def page_size_problems(size)
            return [] if size.match?(PAGE_COUNT) && size.to_i <= MAX_PAGE

            ["page_size #{size.inspect} must be a whole number from 1 to #{MAX_PAGE}"]
          end
        end
      end
    end
  end
end
