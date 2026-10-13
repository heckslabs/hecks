# frozen_string_literal: true

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
            KINDS = %w[text textarea datetime].freeze

            # How a blank value is filled: now, the slug of another attribute, or one piece of it.
            FILL = /\A(?:now|slug_of:\w+|part:\w+:[^:]+:\d+)\z/

            # A wall-clock zone: `Z` or a fixed offset.
            ZONE = /\A(?:Z|[+-]\d\d:\d\d)\z/

            module_function

            # @return [void]
            def apply(aggregates, rows, problems, chapters = [])
              rows.things.each { |row| thing(aggregates, row, problems, chapters) }
              rows.fields.each { |row| field(aggregates, row, problems) }
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
              inward(agg, target, row)
            end

            # A value object of one part is entered as that part, which is what a form is read
            # against, so the flags that decide how a value is read go to the part as well.
            def inward(agg, target, row)
              parts = target["kind"] == "object" ? agg["valueObjects"][target["type"]] : nil
              return unless parts&.size == 1

              parts.first.merge!(flags(row).slice("multiline", "wall", "fill").compact)
            end

            # @return [Hash{String => Object}] what a row writes onto its target: a command takes
            #   only a label and help
            def marks(row)
              base = { "label" => row[:label], "help" => row[:help] }
              base.merge!(flags(row)) unless row[:attribute].to_s.empty?
              base.compact
            end

            def flags(row)
              { "advanced" => (true if row[:advanced]), "multiline" => (true if row[:kind] == "textarea"),
                "wall" => (row[:zone] || "Z" if row[:kind] == "datetime"), "fill" => row[:fill], "picks" => row[:picks] }
            end
          end

          # The checks of one `EditorField` row's own fields.
          module Kinds
            FILL_WORDS = "is now, slug_of:<attribute> or part:<attribute>:<separator>:<index>"

            module_function

            # @return [Array<String>] what is wrong with a row's `kind`, `zone` and `fill`
            def problems(row)
              [*kind(row), *zone(row), *fill(row)]
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
