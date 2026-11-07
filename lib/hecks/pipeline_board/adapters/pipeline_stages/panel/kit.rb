# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      module Panel
        # The drawing the panel's sections share: clipping, padding, boxes of plain ASCII, wrapping
        # a list of items into rows, and the optional colour of a row. A row is `[text, tone]`.
        module Kit
          # The terminal colour code of each tone; a tone with no entry stays plain.
          COLOURS = { "ok" => 32, "done" => 32, "working" => 36, "busy" => 36, "attention" => 33, "failed" => 31,
                      "blocked" => 31, "unknown" => 2 }.freeze
          # The tones from the one that most needs a look to the one that needs none.
          SEVERITY = %w[failed blocked attention unknown working busy ok done].freeze
          # One character for each tone, at the head of a line.
          MARKS = { "ok" => "+", "done" => "+", "working" => "~", "busy" => "~", "attention" => "!", "failed" => "x",
                    "blocked" => "!", "unknown" => "?" }.freeze

          # The line breaks and tabs a row shows as one space.
          BLANKS = /[\t\r\n]+/

          module_function

          # @return [String] the text on one line, cut with `...` when it is longer than `size`
          def clip(text, size)
            flat = text.to_s.gsub(BLANKS, " ").strip
            flat.length > size ? "#{flat[0, [size - 3, 0].max]}..." : flat
          end

          # @return [String] the text in the tone's colour when colour is on, else unchanged
          def paint(text, tone, on)
            code = COLOURS[tone.to_s]
            on && code ? "\e[#{code}m#{text}\e[0m" : text
          end

          # @return [String] the one-character mark of a tone
          def mark(tone) = MARKS.fetch(tone.to_s, "?")

          # @return [String] whichever of the tones most needs a look
          def worst(tones) = tones.min_by { |tone| SEVERITY.index(tone.to_s) || SEVERITY.size }.to_s

          # Packs items into rows no wider than `size`, a row's tone that of its worst item.
          #
          # @param items [Array<Array(String, String)>] each item's text and tone
          # @return [Array<Array(String, String)>] the rows
          def wrap(items, size, gap = "  ")
            rows = []
            items.each { |text, tone| place(rows, text, tone, size, gap) }
            rows.map { |row| [row[:text], worst(row[:tones])] }
          end

          # Puts one item on the last row when it fits there, else on a row of its own.
          def place(rows, text, tone, size, gap)
            last = rows.last
            if last && last[:text].length + gap.length + text.length <= size
              last[:text] = "#{last[:text]}#{gap}#{text}"
              last[:tones] << tone
            else
              rows << { text: text, tones: [tone] }
            end
          end

          # @param title [String] the box's heading, set in its top edge
          # @param rows [Array<Array(String, String)>] the lines inside, each with its tone
          # @param width [Integer] the box's full width
          # @param colour [Boolean] whether rows are coloured by tone
          # @return [Array<String>] the lines of the box, each exactly `width` characters wide
          def box(title, rows, width, colour)
            inner = width - 4
            top = "+- #{clip(title, inner - 1)} ".ljust(width - 1, "-")
            body = rows.map { |text, tone| "| #{paint(clip(text, inner).ljust(inner), tone, colour)} |" }
            ["#{top}+", *body, "+#{"-" * (width - 2)}+"]
          end
        end
      end
    end
  end
end
