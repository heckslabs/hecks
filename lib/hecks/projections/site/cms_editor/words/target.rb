# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        module Words
          # Finds what an `EditorField` row is about, among an aggregate's shaped commands and
          # attributes: a command (the row names no attribute), an attribute everywhere it is
          # declared, or one command's argument, and a part of a value object when the attribute
          # is a dotted path (`sessions.starts_on`).
          module Target
            module_function

            # @param agg [Hash{String => Object}] the aggregate as `Schema` shapes it
            # @param row [Hash{Symbol => Object}] the checked row
            # @return [Array<Hash{String => Object}>] the commands, attributes or parts, in place
            def of(agg, row)
              command = row[:command].to_s
              attribute = row[:attribute].to_s
              commands = agg["commands"].select { |one| command.empty? || one["name"] == command }
              return command.empty? ? [] : commands if attribute.empty?

              head, *rest = attribute.split(".")
              descend(agg, heads(agg, commands, command.empty?, head), rest)
            end

            # @return [Array<Hash{String => Object}>] the attributes named `name` in the aggregate
            #   (when the row names no command) and in the commands
            def heads(agg, commands, everywhere, name)
              lists = commands.map { |one| one["attributes"] }
              lists.unshift(agg["attributes"]) if everywhere
              lists.flat_map { |list| list.select { |attr| attr["name"] == name } }
            end

            # @return [Array<Hash{String => Object}>] the parts named by `path`, walked from `attrs`
            def descend(agg, attrs, path)
              path.reduce(attrs) do |level, name|
                level.flat_map { |attr| (agg["valueObjects"][attr["type"]] || []).select { |part| part["name"] == name } }
              end
            end
          end
        end
      end
    end
  end
end
