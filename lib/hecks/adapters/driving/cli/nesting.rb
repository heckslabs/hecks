module Hecks
  module Adapters
    module Driving
      module Cli
        # Sets values into the nested argument Hash a dotted path names, creating the intermediate
        # Hashes on the way.
        module Nesting
          module_function

          # Appends one element to a list argument, creating the list on first use.
          #
          # Repeats must grow the list (`bury` would silently keep only the last), and a single
          # element is still a one-item list, since a `list_of` attribute must never see a bare
          # object. A leaf fills the last element while that element lacks the field, and
          # otherwise starts the next one, so `a.key=x a.value=y a.key=z a.value=w` makes two
          # elements, each with both fields, in the order they were typed.
          def append(hash, path, value)
            *branches, leaf = path.map(&:to_sym)
            holder = branches[0..-2].reduce(hash) { |node, key| node[key] ||= {} }
            list   = holder[branches.last] ||= []

            place(list, leaf, value)
            hash
          end

          # Sets a leaf into the last element of a list when that element lacks it, else starts a
          # new element with it.
          def place(list, leaf, value)
            current = list.last
            return current[leaf] = value if current.is_a?(Hash) && !current.key?(leaf)

            list << { leaf => value }
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
