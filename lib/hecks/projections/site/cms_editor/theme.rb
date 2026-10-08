# frozen_string_literal: true

require_relative "palette"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The editor's theme as stylesheet text: the light and dark colour properties of a
        # `Palette`, as the lines that go inside the two daisyUI themes `src/browser/app.css`
        # declares (`editor-light`, and `editor-dark` for a visitor whose system prefers dark).
        module Theme
          module_function

          # @param accent [String, nil] the Editor row's accent, a six-digit hex colour, or nil
          # @return [Hash{String => String}] the placeholders of `app.css.tmpl` and their text
          def tokens(accent)
            themes = Palette.new(accent).themes
            { "__LIGHT__" => lines(themes[:light]), "__DARK__" => lines(themes[:dark]) }
          end

          # @param properties [Hash{String => String}] custom properties and their values
          # @return [String] one declaration per line
          def lines(properties) = properties.map { |name, value| "  #{name}: #{value};" }.join("\n")
        end
      end
    end
  end
end
