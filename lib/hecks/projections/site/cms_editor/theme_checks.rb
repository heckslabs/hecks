# frozen_string_literal: true

require_relative "color"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # What the `Editor` row's look settings must satisfy: an accent that is a six-digit hex
        # colour, a logo that is a relative path to a picture file the server can read from its
        # own directory, and a brand that is one line of text.
        module ThemeChecks
          # The file types a logo may be.
          LOGO_TYPES = %w[png jpg jpeg webp gif avif svg].freeze

          # The longest brand the header has room for.
          BRAND_LENGTH = 60

          module_function

          # @param row [Hash{Symbol => String}] the row, defaults filled
          # @return [Array<String>] every problem with `brand`, `accent` and `logo`
          def problems(row)
            [*accent_problems(row[:accent].strip), *logo_problems(row[:logo].strip), *brand_problems(row[:brand].strip)]
          end

          # @return [Array<String>] the problem with an accent that is not blank or six hex digits
          def accent_problems(accent)
            return [] if accent.empty? || Color::HEX.match?(accent)

            ["accent #{accent.inspect} must be a six-digit hex colour such as #1f7a6d"]
          end

          # @return [Array<String>] the problem with a logo that is not a safe relative picture path
          def logo_problems(logo)
            return [] if logo.empty? || safe_path?(logo)

            ["logo #{logo.inspect} must be a relative path to a #{LOGO_TYPES.join(", ")} file, with no .. or hidden part"]
          end

          # @return [Array<String>] the problem with a brand that is long or has more than one line
          def brand_problems(brand)
            return [] if brand.length <= BRAND_LENGTH && !brand.match?(/[[:cntrl:]]/)

            ["brand must be one line of at most #{BRAND_LENGTH} characters"]
          end

          # @return [Boolean] whether `path` is relative, has no hidden part, and is a picture
          def safe_path?(path)
            LOGO_TYPES.include?(File.extname(path).delete_prefix(".").downcase) && !path.start_with?("/") &&
              path.split("/", -1).none? { |part| part.empty? || part.start_with?(".") } && !path.match?(/[\\[:cntrl:]]/)
          end
        end
      end
    end
  end
end
