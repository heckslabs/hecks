# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # What the `Editor` row's settings for many chapters and long lists must satisfy: chapters
        # named once each, roles given for a chapter the editor edits, and a page size a list can
        # hold. A chapter's name is part of an address, so it cannot be spelled as one of the
        # editor's own paths.
        module ScaleChecks
          # The most instances a list may show to a page.
          MAX_PAGE = 1000

          # The first segments of the editor's own addresses, which no chapter may be named.
          RESERVED = %w[assets media logout api].freeze

          module_function

          # @param row [Hash{Symbol => String}] the row, defaults filled
          # @return [Array<String>] every problem with `chapter`, `chapter_roles` and `page_size`
          def problems(row)
            chapters = row[:chapter].split(",").map(&:strip)
            [*chapter_problems(chapters), *role_problems(row[:chapter_roles], chapters), *page_size_problems(row[:page_size])]
          end

          # @return [Array<String>] the problems with an empty, repeated or reserved chapter name
          def chapter_problems(chapters)
            found = []
            found << "chapter names no chapter" if chapters.reject(&:empty?).empty?
            repeated = chapters.find { |name| chapters.count(name) > 1 }
            found << "chapter names #{repeated.inspect} twice" if repeated
            [*found, *reserved_problems(chapters)]
          end

          # @return [Array<String>] a problem for each chapter spelled as an address of the editor's
          def reserved_problems(chapters)
            return [] if chapters.size < 2

            (chapters & RESERVED).map do |name|
              "chapter #{name.inspect} is the first part of an address the editor serves; name it another way"
            end
          end

          # @return [Array<String>] the problems with `Chapter=Role,Role;Chapter=Role` entries
          def role_problems(text, chapters)
            text.split(";").map(&:strip).reject(&:empty?).flat_map do |entry|
              name, roles = entry.split("=", 2)
              next ["chapter_roles #{entry.inspect} must read Chapter=Role,Role"] if roles.to_s.strip.empty?
              next [] if chapters.include?(name.strip)

              ["chapter_roles names #{name.strip.inspect}, which is not a chapter of this editor"]
            end
          end

          # @return [Array<String>] the problem with a page size that is not a whole 1 to 1000
          def page_size_problems(size)
            return [] if size.match?(/\A[1-9]\d{0,3}\z/) && size.to_i <= MAX_PAGE

            ["page_size #{size.inspect} must be a whole number from 1 to #{MAX_PAGE}"]
          end
        end
      end
    end
  end
end
