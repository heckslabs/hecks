module Hecks
  module Adapters
    module Driving
      module Cli
        # Checks that the repeated fields of a list of value objects, given as columns on the
        # command line, make whole rows: every field a row needs is given once per row.
        module Columns
          module_function

          # Refuses a list whose columns differ in length, naming every column and its count.
          #
          # @param args [Hash{Symbol => Object}] the arguments built from the command line
          # @param options [Hash{String => Hash}] the command's declared arguments, by path
          # @raise [Runtime::TypeMismatch] if a required column is shorter than the longest one
          def check!(args, options)
            groups(options).each do |parent, fields|
              list = dig(args, parent)
              next unless list.is_a?(Array)

              counts = fields.to_h { |field| [field, list.count { |row| row.key?(field[:leaf].to_sym) }] }
              raise Runtime::TypeMismatch, refusal(parent, counts) unless whole?(counts, list.length)
            end
          end

          # The fields of each multi-field list argument, by the path of the list.
          def groups(options)
            fields = options.values.select { |argument| argument[:list] && !argument[:words] }
            fields.map { |argument| argument.merge(leaf: argument[:path].split(".").last) }
                  .group_by { |field| parent_of(field[:path]) }.reject { |_, group| group.one? }
          end

          # The dotted path of the list a field belongs to.
          def parent_of(path)
            path.split(".")[0..-2].join(".")
          end

          # Whether every column that is required, or given at all, has one word per row.
          def whole?(counts, rows)
            counts.all? { |field, count| count == rows || (count.zero? && !field[:required]) }
          end

          # The words of the refusal: each column with its count.
          def refusal(parent, counts)
            columns = counts.map { |field, count| "#{field[:leaf]} #{count}" }.join(", ")
            "#{parent} columns differ in length: #{columns}; give each #{parent}.* field once per row"
          end

          # The value at a dotted path, or nil.
          def dig(args, path)
            path.split(".").reduce(args) { |node, key| node.is_a?(Hash) ? node[key.to_sym] : nil }
          end
        end
      end
    end
  end
end
