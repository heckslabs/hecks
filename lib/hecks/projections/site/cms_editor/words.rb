# frozen_string_literal: true

require_relative "../root_rows"
require_relative "../payload_driver"
require_relative "words/marks"
require_relative "words/payload"
require_relative "words/companions"
require_relative "words/families"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The words an editor says to people, declared beside the route table as rows of three
        # value objects, because the domain's own names (`Revise`, `Sections`, a slug) say what the
        # model is, not what a person does. They are the site's side of the editor, like the
        # `Editor` row: the domain's bluebook stays free of them.
        #
        # `EditorThing` names an aggregate to a person (`name`, `plural`, `about`, a `preview`
        # address of its own, `advanced` to tuck it away). `EditorField` is about an attribute, or
        # with no attribute a command: a `label`, a `help` sentence, a `kind` (`textarea`, or
        # `datetime` with the `zone` its wall-clock times are in), whether it is `advanced`, which
        # aggregate it `picks` from, and how it is `fill`ed when left blank. `EditorCompanion` is a
        # record of another aggregate that belongs to this one's records by a key made of theirs
        # (`news.{slug}.body`), shown on their page as one thing.
        module Words
          # What a row of each object may carry.
          THINGS = RootRows.new("EditorThing", many: true, required: %i[aggregate],
                                fields: { aggregate: String, name: String, plural: String, about: String, preview: String,
                                          advanced: [TrueClass, FalseClass] })

          FIELDS = RootRows.new("EditorField", many: true, required: %i[aggregate],
                                fields: { aggregate: String, command: String, attribute: String, label: String, help: String,
                                          kind: String, zone: String, advanced: [TrueClass, FalseClass], picks: String,
                                          fill: String, after: String })

          COMPANIONS = RootRows.new("EditorCompanion", many: true, required: %i[aggregate with key field],
                                    fields: { aggregate: String, with: String, key: String, field: String, when: String,
                                              label: String, help: String })

          # `EditorFamily`: aggregates a person thinks of as one kind of thing (the five types of a page)
          # listed together as one job, each record shown with which of them it is. `members` are the
          # aggregates, `titles` is an aggregate whose identity is the part of a member's key after the
          # first colon and which names the record to a person (its title, name or label) and says
          # whether it shows.
          FAMILIES = RootRows.new("EditorFamily", many: true, required: %i[name members],
                                  fields: { name: String, plural: String, about: String, members: String, titles: String })

          # The checked rows of a route chapter; `payload` are the `PayloadField` rows a project
          # declares for its content system, which the editor reads for the same facts.
          Rows = Struct.new(:things, :fields, :companions, :payload, :zone, :families) do
            def none? = [things, fields, companions, payload, families].all?(&:empty?)
          end

          module_function

          # @param chapter [Bluebook::Chapter] the chapter that declares the route table
          # @return [Rows] the checked rows, each list empty when the chapter declares none
          # @raise [Table::Invalid] when a row is refused
          def read(chapter)
            payload = PayloadDriver::FIELD.read(chapter)
            Rows.new(THINGS.read(chapter), FIELDS.read(chapter), COMPANIONS.read(chapter), payload, "Z", FAMILIES.read(chapter))
          end

          # @param aggregates [Array<Hash{String => Object}>] the aggregates as `Schema` shapes them
          # @param rows [Rows] the checked rows
          # @param chapters [Array<String>] the chapters the editor edits, which a row may name
          # @return [Array<Hash{String => Object}>] the aggregates, each carrying what its rows say
          # @raise [Table::Invalid] naming every row that names something the chapters do not have
          def apply(aggregates, rows, chapters: [])
            return aggregates if rows.nil? || rows.none?

            Payload.apply(aggregates, rows.payload, rows.zone || "Z")
            problems = []
            Marks.apply(aggregates, rows, problems, chapters)
            refuse("editor's words", problems)
            aggregates
          end

          # @param what [String] what is refused, for the first line
          # @param problems [Array<String>] each reason, one line each
          # @raise [Table::Invalid] naming every problem, when there is one
          def refuse(what, problems)
            return if problems.empty?

            raise Table::Invalid, "the #{what} are refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
          end

          # @param aggregates [Array<Hash{String => Object}>] the aggregates, with their words
          # @param rows [Rows] the checked rows
          # @param chapters [Array<String>] the chapters, whose names a family may not take
          # @return [Array<Hash{String => Object}>] the families the rows declare, as `schema.ts` reads them
          # @raise [Table::Invalid] naming every row that names something the chapters do not have
          def families(aggregates, rows, chapters: [])
            return [] if rows.nil? || rows.families.empty?

            Families.build(aggregates, rows.families, chapters)
          end

          # @return [Array<Hash{String => Object}>] the aggregates with each companion record
          #   among the `related` panels of the aggregate it goes with
          # @raise [Table::Invalid] when a companion names what the chapters do not have
          def companions(aggregates, rows)
            return aggregates if rows.nil? || rows.companions.empty?

            Companions.apply(aggregates, rows.companions)
          end
        end
      end
    end
  end
end
