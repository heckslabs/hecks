# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # Colour arithmetic for the editor's theme: parsing and writing six-digit hex, moving
        # between red-green-blue and hue-saturation-lightness, mixing, and the contrast ratio the
        # web accessibility guidelines define. Pure functions of their inputs, so the theme the
        # editor is generated with is the same on every run.
        module Color
          # A six-digit hex colour with its leading hash.
          HEX = /\A#[0-9a-fA-F]{6}\z/

          # The step by which `reach` moves a colour's lightness while it searches.
          STEP = 0.01

          module_function

          # @param value [String] a colour such as `"#1f7a6d"`
          # @return [Array<Float>] its red, green and blue, each from 0.0 to 1.0
          def rgb(value) = value.delete_prefix("#").scan(/../).map { |pair| pair.hex / 255.0 }

          # @param channels [Array<Float>] red, green and blue, each from 0.0 to 1.0
          # @return [String] the colour as lower-case hex
          def hex(channels)
            channels.each_with_object(+"#") { |c, text| text << format("%02x", (c.clamp(0.0, 1.0) * 255).round) }
          end

          # @param value [String] a colour
          # @return [Array<Float>] hue in degrees, then saturation and lightness from 0.0 to 1.0
          def hsl(value)
            red, green, blue = rgb(value)
            high = [red, green, blue].max
            low = [red, green, blue].min
            light = (high + low) / 2.0
            return [0.0, 0.0, light] if high == low

            spread = high - low
            sat = light > 0.5 ? spread / (2.0 - high - low) : spread / (high + low)
            [angle(red, green, blue, high, spread), sat, light]
          end

          # @param hue [Float] degrees
          # @param sat [Float] saturation from 0.0 to 1.0
          # @param light [Float] lightness from 0.0 to 1.0
          # @return [String] the colour as hex
          def from_hsl(hue, sat, light)
            chroma = (1 - ((2 * light) - 1).abs) * sat
            shift = light - (chroma / 2)
            hex(sector(hue % 360, chroma, second(hue % 360, chroma)).map { |channel| channel + shift })
          end

          # @return [Float] the second-largest channel of a colour of the given hue and chroma
          def second(hue, chroma) = chroma * (1 - (((hue / 60.0) % 2) - 1).abs)

          # @param one [String] a colour
          # @param other [String] another colour
          # @param share [Float] how much of `other` goes in, from 0.0 to 1.0
          # @return [String] the colours mixed channel by channel
          def mix(one, other, share) = hex(rgb(one).zip(rgb(other)).map { |a, b| (a * (1 - share)) + (b * share) })

          # @param value [String] a colour
          # @return [Float] its relative luminance as the accessibility guidelines define it
          def luminance(value)
            red, green, blue = rgb(value).map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
            (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
          end

          # @param one [String] a colour
          # @param other [String] another colour
          # @return [Float] the contrast ratio, from 1.0 to 21.0
          def contrast(one, other)
            high = [luminance(one), luminance(other)].max
            low = [luminance(one), luminance(other)].min
            (high + 0.05) / (low + 0.05)
          end

          # Moves a colour's lightness, a little at a time, until it reads against every background.
          #
          # @param value [String] where to start
          # @param against [Array<String>] backgrounds the colour must read on
          # @param ratio [Float] the least contrast to reach
          # @param toward [Symbol] `:darker` or `:lighter`
          # @return [String] `value` itself when it already reads, else the nearest such colour
          def reach(value, against, ratio, toward)
            hue, sat, light = hsl(value)
            sign = toward == :darker ? -STEP : STEP
            light += sign until light.round(2).clamp(0.0,
                                                     1.0) != light.round(2) || reads?(from_hsl(hue, sat, light), against, ratio)
            from_hsl(hue, sat, light.clamp(0.0, 1.0))
          end

          # @param value [String] a colour
          # @param against [Array<String>] backgrounds
          # @param ratio [Float] the least contrast
          # @return [Boolean] whether `value` reaches `ratio` on every background
          def reads?(value, against, ratio) = against.all? { |back| contrast(value, back) >= ratio }

          # @param background [String] a fill
          # @param light [String] a light foreground to try
          # @param dark [String] a dark foreground to try
          # @return [String] whichever reads better on `background`
          def foreground(background, light, dark) = contrast(light, background) >= contrast(dark, background) ? light : dark

          # @return [Float] the hue, in degrees, of a colour given by its channels
          def angle(red, green, blue, high, spread)
            degrees = if high == red then ((green - blue) / spread) % 6
                      elsif high == green then ((blue - red) / spread) + 2
                      else ((red - green) / spread) + 4
                      end
            degrees * 60.0
          end

          # @return [Array<Float>] the red, green and blue before lightness is added back
          def sector(hue, chroma, mid)
            [[chroma, mid, 0], [mid, chroma, 0], [0, chroma, mid], [0, mid, chroma], [mid, 0, chroma],
             [chroma, 0, mid]][(hue / 60).floor % 6]
          end
        end
      end
    end
  end
end
