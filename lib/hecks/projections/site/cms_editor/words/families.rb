# frozen_string_literal: true

require_relative "marks"

module Hecks
  module Projections
    module Site
      module CmsEditor
        module Words
          # Reads the `EditorFamily` rows into the schema's `families`: one job that lists the records
          # of several aggregates together and says which aggregate each is. A family is a view over its
          # members; each member keeps its own address, forms and commands.
          module Families
            module_function

            # @param aggregates [Array<Hash{String => Object}>] the aggregates as `Schema` shapes them
            # @param rows [Array<Hash{Symbol => Object}>] the checked `EditorFamily` rows
            # @param chapters [Array<String>] the chapters, whose names a family key may not take
            # @return [Array<Hash{String => Object}>] each family: key, words, chapter, member keys and `titles`
            # @raise [Table::Invalid] naming every row that names what the chapters do not have
            def build(aggregates, rows, chapters)
              problems = []
              built = rows.filter_map { |row| one(aggregates, row, chapters, problems) }
              built.map { |family| family["key"] }.tally.each do |key, count|
                problems << "EditorFamily #{key.inspect} is declared twice" if count > 1
              end
              Words.refuse("EditorFamily rows", problems)
              built
            end

            # @return [Hash{String => Object}, nil] the family, or nil with each problem noted
            def one(aggregates, row, chapters, problems)
              members = members_of(aggregates, row, problems)
              titles = titles_of(aggregates, row, problems)
              return nil unless members

              key = key_of(row)
              problems << "EditorFamily #{row[:name]}: its address #{key.inspect} is a chapter's name" if chapters.include?(key)
              if members.map { |agg| agg["chapter"] }.uniq.size > 1
                problems << "EditorFamily #{row[:name]}: its members are in different chapters"
              end
              shape(row, key, members, titles)
            end

            # @return [Array<Hash{String => Object}>, nil] the member aggregates, or nil when one is missing
            def members_of(aggregates, row, problems)
              names = row[:members].to_s.split(",").map(&:strip).reject(&:empty?)
              found = names.map { |name| Marks.find(aggregates, name) }
              names.zip(found).each { |name, agg| problems << missing(row, name) unless agg }
              found.all? ? found : nil
            end

            def missing(row, name) = "EditorFamily #{row[:name]}: member #{name.inspect} is no aggregate of the chapters"

            # @return [Hash{String => Object}, nil] the aggregate that titles the members, when the row names one
            def titles_of(aggregates, row, problems)
              return nil unless row[:titles]

              found = Marks.find(aggregates, row[:titles])
              return found if found

              problems << "EditorFamily #{row[:name]}: titles #{row[:titles].inspect} is no aggregate of the chapters"
              nil
            end

            def key_of(row) = (row[:plural] || "#{row[:name]}s").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")

            def shape(row, key, members, titles)
              { "key" => key, "name" => row[:name], "plural" => row[:plural] || "#{row[:name]}s", "about" => row[:about],
                "chapter" => members.first["chapter"], "members" => members.map { |agg| keyed(agg) },
                "titles" => (keyed(titles) if titles) }.compact
            end

            # What `names.ts` calls an aggregate: the chapter and name when the editor spans several.
            def keyed(agg) = agg["chapter"] ? "#{agg["chapter"]}.#{agg["name"]}" : agg["name"]
          end
        end
      end
    end
  end
end
