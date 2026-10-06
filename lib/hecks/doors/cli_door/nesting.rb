module Hecks
  module Doors
    module CliDoor
      # Sets values into the nested argument Hash a dotted path names, creating the intermediate
      # Hashes on the way.
      module Nesting
        module_function

        # Appends one element to a list argument, creating the list on first use.
        #
        # Repeats must grow the list (`bury` would silently keep only the last), and a single
        # element is still a one-item list, since a `list_of` attribute must never see a bare
        # object. Multi-field elements are left to `JsonDoor`: a flat command line cannot say
        # which `a.x=` pairs with which `a.y=`.
        def append(hash, path, value)
          *branches, leaf = path.map(&:to_sym)
          holder = branches[0..-2].reduce(hash) { |node, key| node[key] ||= {} }
          list   = holder[branches.last] ||= []

          list << { leaf => value }
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
