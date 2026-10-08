# frozen_string_literal: true

require_relative "color"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The editor's colours, light and dark, derived from one accent colour, as the custom
        # properties of a daisyUI theme (`--color-base-100`, `--color-primary`, ...) and the few
        # extras the pages use (`--ed-muted`, `--ed-edge`). Every text and fill pair is moved
        # until it reaches the accessibility standard's level for it (4.5:1 for text, 3:1 for the
        # edge of a control), so a brand colour that would fail cannot make the editor unreadable.
        #
        # The neutrals (ground, page, ink, muted ink, rule) are fixed when the row names no
        # accent, and take the accent's hue at low saturation when it does, so an accent retints
        # the whole theme. Primary buttons are filled with ink (daisyUI's `neutral`); the accent
        # (`primary`) marks selection, focus, links, the active navigation item and the saved or
        # published state.
        class Palette
          # The accent a row that names none gets: a deep verdigris.
          DEFAULT_ACCENT = "#1f7a6d"

          # The neutrals a row that names no accent gets, per theme.
          FIXED = {
            light: { ground: "#f4f6f8", surface: "#ffffff", ink: "#1a222c", muted: "#5a6675", rule: "#dce1e7" },
            dark:  { ground: "#11161b", surface: "#181f26", ink: "#e7ebef", muted: "#9aa6b3", rule: "#28313b" }
          }.freeze

          # Hues of the status colours, in degrees.
          TONES = { ok: 150.0, warn: 38.0, danger: 4.0 }.freeze

          # The daisyUI variable each status tone fills.
          STATUS = { ok: "success", warn: "warning", danger: "error" }.freeze

          # @param accent [String, nil] a six-digit hex colour, or nil for the default
          def initialize(accent = nil)
            @custom = !accent.to_s.empty?
            @accent = (accent.to_s.empty? ? DEFAULT_ACCENT : accent).downcase
          end

          # @return [Hash{Symbol => Hash{String => String}}] each theme's properties, name to value
          def themes = { light: properties(:light), dark: properties(:dark) }

          private

          def properties(theme)
            base = neutrals(theme)
            found = base.merge(accents(theme, base)).merge(tones(theme, base))
            { **daisy(found), **extras(found) }
          end

          def lighter(theme) = theme == :light ? :darker : :lighter

          def neutrals(theme)
            fixed = @custom ? tinted(FIXED.fetch(theme)) : FIXED.fetch(theme)
            backs = [fixed[:surface], fixed[:ground]]
            edge = Color.reach(Color.mix(fixed[:rule], fixed[:muted], 0.5), backs, 3.0, lighter(theme))
            { **fixed, muted: Color.reach(fixed[:muted], backs, 4.5, lighter(theme)), edge: edge }
          end

          # The fixed neutrals with the accent's hue at the saturation each already has.
          def tinted(fixed)
            hue = Color.hsl(@accent).first
            fixed.transform_values do |hex|
              _, sat, light = Color.hsl(hex)
              hex == "#ffffff" ? hex : Color.from_hsl(hue, sat, light)
            end
          end

          def accents(theme, base)
            backs = [base[:surface], base[:ground]]
            fill = theme == :light ? @accent : Color.reach(@accent, backs, 4.5, :lighter)
            soft = Color.mix(base[:surface], fill, theme == :light ? 0.1 : 0.18)
            { primary: Color.reach(fill, [*backs, soft], 4.5, lighter(theme)), accent_soft: soft }
          end

          def tones(theme, base)
            TONES.each_with_object({}) do |(name, hue), found|
              back = theme == :light ? Color.from_hsl(hue, 0.5, 0.94) : Color.from_hsl(hue, 0.28, 0.18)
              start = Color.from_hsl(hue, 0.55, theme == :light ? 0.3 : 0.72)
              found[:"#{name}_bg"] = back
              found[:"#{name}_fg"] = Color.reach(start, [back, base[:surface]], 4.5, lighter(theme))
            end
          end

          # The first of white, a near-black and black that reads on `fill`.
          def on(fill) = ["#ffffff", "#0f151a", "#000000"].find { |hex| Color.contrast(hex, fill) >= 4.5 }

          def daisy(found)
            colours = surfaces(found).merge(fills(found))
            named = colours.slice("primary", "secondary", "accent", "info", *STATUS.values)
            contents = named.to_h { |name, value| ["#{name}-content", on(value)] }
            colours.merge(contents).transform_keys { |name| "--color-#{name}" }
          end

          def surfaces(found)
            { "base-100" => found[:surface], "base-200" => found[:ground], "base-300" => found[:rule],
              "base-content" => found[:ink], "neutral" => found[:ink], "neutral-content" => found[:surface] }
          end

          def fills(found)
            { "primary" => found[:primary], "secondary" => found[:muted], "accent" => found[:primary], "info" => found[:primary],
              **STATUS.to_h { |tone, name| [name, found[:"#{tone}_fg"]] } }
          end

          def extras(found)
            { "--ed-muted" => found[:muted], "--ed-edge" => found[:edge], "--ed-soft" => found[:accent_soft],
              "--ed-ok-bg" => found[:ok_bg], "--ed-warn-bg" => found[:warn_bg], "--ed-danger-bg" => found[:danger_bg] }
          end
        end
      end
    end
  end
end
