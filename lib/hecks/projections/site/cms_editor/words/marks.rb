# frozen_string_literal: true

require_relative "../checks"
require_relative "target"

module Hecks
  module Projections
    module Site
      module CmsEditor
        module Words
          # Writes what `EditorThing` and `EditorField` rows say onto the aggregates in place: an
          # aggregate's `words`, an attribute's `label`, `help`, `advanced`, `multiline`, `wall`,
          # `fill` and `picks`, a command's `label` and `help`. Each row that names an aggregate,
          # command or attribute the chapters do not have adds a problem instead.
          module Marks
            # The kinds an `EditorField` may name.
            KINDS = %w[text textarea datetime markdown image file].freeze

            # A key kind word, as `KeyKinds` reads one.
            KIND_WORD = /\A[a-z][a-z0-9_]*\z/

            # The kinds that are an upload: `image` takes pictures, `file` takes PDFs, and `picks`
            # names the content system's collection that keeps them (`media`, `documents`).
            UPLOADS = { "image" => "image", "file" => "pdf" }.freeze

            # How a blank value is filled: now, the slug of another attribute, or one piece of it.
            FILL = /\A(?:now|slug_of:\w+|part:\w+:[^:]+:\d+)\z/

            # A wall-clock zone: `Z` or a fixed offset.
            ZONE = Checks::ZONE

            module_function

            # @return [void]
            def apply(aggregates, rows, problems, chapters = [])
              rows.things.each { |row| thing(aggregates, row, problems, chapters) }
              rows.fields.each { |row| field(aggregates, row, problems) }
              (rows.runs || []).each { |row| run(aggregates, row, problems) }
            end

            # An `EditorRun` row must name an aggregate and commands it has.
            def run(aggregates, row, problems)
              agg = find(aggregates, row[:aggregate])
              return problems << "EditorRun names no aggregate #{row[:aggregate].inspect}" unless agg

              problems.concat(unknown_commands(agg, row))
            end

            # @return [Array<String>] one line for each command a run row names the aggregate lacks
            def unknown_commands(agg, row)
              missing = listed(row[:command]).to_a - agg["commands"].map { |command| command["name"] }
              missing.map { |name| "EditorRun #{row[:aggregate]}.#{row[:action]}: #{agg["name"]} has no command #{name.inspect}" }
            end

            # @return [Hash{String => Object}, nil] the aggregate named `Name` or `Chapter::Name`
            def find(aggregates, name)
              chapter, bare = name.include?("::") ? name.split("::", 2) : [nil, name]
              aggregates.find { |agg| agg["name"] == bare && (chapter.nil? || agg["chapter"] == chapter) }
            end

            def thing(aggregates, row, problems, chapters)
              agg = find(aggregates, row[:aggregate])
              return chapter(aggregates, row, problems, chapters) unless agg

              words = row.slice(:name, :plural, :about, :preview).transform_keys(&:to_s)
              words["advanced"] = true if row[:advanced]
              agg["words"] = words unless words.empty?
            end

            # A row that names a chapter instead gives the chapter its title in the navigation.
            def chapter(aggregates, row, problems, chapters)
              held = aggregates.select { |agg| agg["chapter"] == row[:aggregate] }
              if held.empty?
                known = chapters.include?(row[:aggregate])
                problems << "EditorThing names no aggregate or chapter #{row[:aggregate].inspect}" unless known
                return
              end

              held.each { |agg| agg["chapterTitle"] = row.fetch(:name, row[:plural]) }
            end

            def field(aggregates, row, problems)
              agg = find(aggregates, row[:aggregate])
              return problems << "EditorField names no aggregate #{row[:aggregate].inspect}" unless agg

              where = [row[:aggregate], row[:command], row[:attribute]].compact.reject(&:empty?).join(".")
              held = Target.of(agg, row)
              held.each { |target| write(agg, target, row) }
              problems.concat(noted(row, where, held))
            end

            # @return [Array<String>] what is wrong with a row, each line led by where it is
            def noted(row, where, held)
              found = Kinds.problems(row)
              found << "names nothing in the chapters" if held.empty?
              found.map { |text| "EditorField #{where}: #{text}" }
            end

            def write(agg, target, row)
              target.merge!(marks(row))
              inward(agg, target, flags(row))
            end

            # A value object of one part is entered as that part, which is what a form is read
            # against, so the flags that decide how a value is read go to the part as well.
            def inward(agg, target, marked)
              parts = target["kind"] == "object" ? agg["valueObjects"][target["type"]] : nil
              return unless parts&.size == 1

              parts.first.merge!(marked.slice("multiline", "markdown", "upload", "wall", "fill", "widget", "after", "options",
                                              "optionLabels").compact)
            end

            # @return [Hash{String => Object}] what a row writes onto its target: a command takes
            #   only a label and help
            def marks(row)
              base = { "label" => row[:label], "help" => row[:help] }
              base.merge!(flags(row)) unless row[:attribute].to_s.empty?
              named(base).compact
            end

            # A label of `Singular|Plural` is a list's: the plural is the label, the singular is what one
            # of its items is called (`noun`), as the content system's field rows say it.
            def named(base)
              single, plural = base["label"].to_s.split("|", 2)
              return base if plural.nil?

              base.merge("label" => plural, "noun" => single.downcase)
            end

            def flags(row)
              { "advanced" => (true if row[:advanced]), "multiline" => (true if %w[textarea markdown].include?(row[:kind])),
                "markdown" => (true if row[:kind] == "markdown"), "wall" => (row[:zone] || "Z" if row[:kind] == "datetime"),
                "fill" => row[:fill], "after" => row[:after], "keys" => listed(row[:keys]), **choices(row[:options]),
                **uploading(row) }
            end

            # @return [Array<String>, nil] the words of a comma separated list, or nil when empty
            def listed(text)
              words = text.to_s.split(",").map(&:strip).reject(&:empty?)
              words.empty? ? nil : words
            end

            # @return [Hash{String => Object}] the closed set a row's `options` names (`a,b` or
            #   `a=Label,b=Label`), in the form the content system's rows use
            def choices(text) = listed(text) ? Payload.options(text.to_s) : {}

            # @return [Hash{String => Object}] the upload mark of an `image` or `file` row, whose
            #   `picks` names a collection, else the aggregate the row picks from
            def uploading(row)
              return { "picks" => row[:picks] } unless UPLOADS.key?(row[:kind])

              { "upload" => Upload.of(UPLOADS.fetch(row[:kind]), row[:picks]) }
            end
          end

          # What an upload mark holds: the collection the content system keeps the files in,
          # and what it accepts there (`image` or `pdf`).
          module Upload
            module_function

            # @return [Hash{String => String}] the mark
            def of(accept, collection)
              { "collection" => collection.to_s, "accept" => accept }
            end
          end

          # The checks of one `EditorField` row's own fields.
          module Kinds
            FILL_WORDS = "is now, slug_of:<attribute> or part:<attribute>:<separator>:<index>"

            module_function

            # @return [Array<String>] what is wrong with a row's `kind`, `zone` and `fill`
            def problems(row)
              [*kind(row), *zone(row), *fill(row), *upload(row), *keys(row)]
            end

            # @return [Array<String>] the words of `keys` that are not a lower-case kind word
            def keys(row)
              bad = Marks.listed(row[:keys]).to_a.grep_v(Marks::KIND_WORD)
              bad.map { |word| "keys #{word.inspect} is not a kind word (lower case letters, digits and underscores)" }
            end

            # @return [Array<String>] the problem with an upload that names no collection
            def upload(row)
              return [] unless Marks::UPLOADS.key?(row[:kind]) && row[:picks].to_s.empty?

              ["kind #{row[:kind]} needs picks: the content system's collection the files are kept in"]
            end

            def kind(row)
              return [] if row[:kind].nil? || Marks::KINDS.include?(row[:kind])

              ["kind #{row[:kind].inspect} is not one of #{Marks::KINDS.join(", ")}"]
            end

            def zone(row)
              return [] unless row[:zone]

              found = []
              found << "zone #{row[:zone].inspect} is Z or an offset like -07:00" unless Marks::ZONE.match?(row[:zone])
              found << "zone needs kind datetime" unless row[:kind] == "datetime"
              found
            end

            def fill(row)
              return [] if row[:fill].nil? || Marks::FILL.match?(row[:fill])

              ["fill #{row[:fill].inspect} #{FILL_WORDS}"]
            end
          end
        end
      end
    end
  end
end
