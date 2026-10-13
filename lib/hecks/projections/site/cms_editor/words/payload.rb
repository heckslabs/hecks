# frozen_string_literal: true

require_relative "target"

module Hecks
  module Projections
    module Site
      module CmsEditor
        module Words
          # Reads the `PayloadField` rows a project already declares for a content system and says
          # the same things to the editor, so the words of a field are written once: its `label`
          # (a list's is `Singular|Plural`), its `description` as the help under it, `kind`
          # (`textarea`; `select` with its `options`; `date` and `day`; `relationship`), `required`
          # (false is "optional" in the caption), and `default`. A row of a kind the editor cannot
          # honour (`upload` with no `relation`) is read for its words only; with one it is an
          # upload of that collection, taking pictures or, when `options` is `pdf`, PDFs.
          #
          # A row is read leniently: one that names an aggregate the editor does not edit, or an
          # attribute the chapters lack, is the other projection's to refuse and is skipped here.
          module Payload
            # `date` and `day` on an integer: whole seconds since 1970, shown as a date or a moment.
            WIDGETS = { "date" => "datetime", "day" => "date" }.freeze

            module_function

            # @param aggregates [Array<Hash{String => Object}>] the aggregates, from `Schema`
            # @param rows [Array<Hash{Symbol => Object}>] the checked `PayloadField` rows
            # @param zone [String] the zone a text moment is entered in (`Z` or an offset)
            # @return [void]
            def apply(aggregates, rows, zone)
              rows.each do |row|
                agg = Marks.find(aggregates, row[:aggregate])
                next unless agg

                targets = Target.of(agg, row)
                targets.each do |target|
                  marked = marks(row, target, aggregates, zone)
                  target.merge!(marked)
                  Marks.inward(agg, target, marked)
                end
              end
            end

            # @return [Hash{String => Object}] what a row says about one attribute, nothing for
            #   what it leaves unsaid
            def marks(row, target, aggregates, zone)
              singular, plural = row[:label].to_s.split("|", 2)
              plural ||= singular.to_s.empty? ? nil : "#{singular}s"
              { "label" => (plural unless singular.to_s.empty?), "noun" => (singular.downcase unless singular.to_s.empty?),
                "help" => row[:description], "softOptional" => (true if row[:required] == false), "default" => row[:default],
                **kind(row, target, aggregates, zone) }.compact
            end

            def kind(row, target, aggregates, zone)
              case row[:kind]
              when "textarea" then { "multiline" => true }
              when "select" then options(row[:options].to_s)
              when "markdown" then { "multiline" => true, "markdown" => true }
              when "upload" then upload(row)
              when "date", "day" then moment(row[:kind], target, zone)
              when "relationship" then relation(row[:relation].to_s, aggregates)
              else {}
              end
            end

            # An upload row names the collection (`relation`) that keeps the file, and what it takes
            # in `options`: `pdf`, else pictures. A row with no relation is words only.
            #
            # @return [Hash{String => Object}] the `upload` mark, or none
            def upload(row)
              return {} if row[:relation].to_s.empty?

              { "upload" => Upload.of(row[:options].to_s.strip == "pdf" ? "pdf" : "image", row[:relation]) }
            end

            # @return [Hash{String => Object}] `options`, and `optionLabels` for `value=Label` pairs
            def options(text)
              pairs = text.split(",").map(&:strip).reject(&:empty?).map { |item| item.split("=", 2) }
              labels = pairs.select { |pair| pair.size == 2 }.to_h
              found = { "options" => pairs.map(&:first), "optionLabels" => labels }
              found.reject { |_, value| value.empty? }
            end

            # An integer is a date or a moment by the kind; a text is the clock of the zone.
            def moment(kind, target, zone)
              integer = target["kind"] == "integer" || target["type"] == "Integer"
              return { "widget" => WIDGETS.fetch(kind) } if integer
              return {} if kind == "day"

              { "wall" => zone }
            end

            # @return [Hash{String => Object}] `picks` when the relation's collection names an
            #   aggregate the editor edits (`practice-texts` is `PracticeText`)
            def relation(slug, aggregates)
              noun = slug.split("-").map(&:capitalize).join.sub(/ies\z/, "y").delete_suffix("s")
              found = aggregates.select { |agg| agg["name"] == noun }
              found.size == 1 ? { "picks" => noun } : {}
            end
          end
        end
      end
    end
  end
end
