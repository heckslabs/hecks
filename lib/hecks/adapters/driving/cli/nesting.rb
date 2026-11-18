module Hecks
  module Adapters
    module Driving
      module Cli
        # Sets values into the nested argument Hash a dotted path names, creating the intermediate
        # Hashes on the way.
        module Nesting
          module_function

          # Appends one word of a list argument, creating the list on first use.
          #
          # A repeated name grows the list, and a single element is still a one-item list, since a
          # `list_of` attribute must never see a bare object. A value object's fields are columns:
          # each word goes into the first element still lacking that field, so the nth `a.x=` and
          # the nth `a.y=` make the nth element. `Columns` refuses columns of different lengths.
          def append(hash, path, value)
            *branches, leaf = path.map(&:to_sym)
            holder = branches[0..-2].reduce(hash) { |node, key| node[key] ||= {} }
            list   = holder[branches.last] ||= []

            (list.find { |element| !element.key?(leaf) } || list.push({}).last)[leaf] = value
            hash
          end

          # Sets one value at a nested path, creating intermediate Hashes and overwriting the leaf.
          def bury(hash, path, value)
            *branches, leaf = path.map(&:to_sym)
            target = branches.reduce(hash) { |node, key| node[key] ||= {} }
            target[leaf] = value
            hash
          end
        end
      end
    end
  end
end
