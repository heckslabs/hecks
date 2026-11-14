# frozen_string_literal: true

module Hecks
  module Fuzzing
    class DeliverySimulation
      # A git repository held in memory: commits by their parents, and the refs that name them.
      #
      # It stands where the landing and train adapters reach git, so a simulation runs no process
      # and writes no file. Commit ids are counted, not hashed, so one schedule names the same
      # commits every time it is replayed.
      class Repository
        # Raised when a ref names another commit than the one a move expected.
        class Moved < StandardError; end

        # The local branch every landing lands on.
        MAIN = "main"

        # The remote's copy of it, which only the train moves.
        ORIGIN = "origin/main"

        # @param tag [String] the lead of every commit id, unique to one replay
        def initialize(tag)
          @tag = tag
          @parents = {}
          @refs = {}
          root = commit([])
          @refs[MAIN] = root
          @refs[ORIGIN] = root
        end

        # @param ref [String] a ref's name
        # @return [String, nil] the commit it names
        def tip(ref) = @refs[ref]

        # @param id [String, nil] a commit id
        # @return [Boolean] whether this repository made it
        def known?(id) = @parents.key?(id)

        # Makes a commit.
        #
        # @param parents [Array<String>] the commits it is built on
        # @return [String] its id
        def commit(parents)
          id = "#{@tag}-c#{@parents.size + 1}"
          @parents[id] = parents
          id
        end

        # Opens a branch one commit ahead of another ref.
        #
        # @param name [String] the new branch
        # @param from [String] the ref it starts at
        # @return [String] the branch's tip
        def branch(name, from: MAIN)
          @refs[name] = commit([tip(from)])
        end

        # The commit that holds both sides: the later one when one holds the other, else a new
        # merge commit.
        #
        # @param onto [String] the commit merged onto
        # @param tip [String] the commit merged in
        # @return [String] the commit holding both
        def merge(onto, tip)
          return tip if ancestor?(onto, tip)
          return onto if ancestor?(tip, onto)

          commit([onto, tip])
        end

        # Moves a ref only if it still names what the caller read: a compare-and-swap.
        #
        # @param ref [String] the ref to move
        # @param to [String] the commit it should name
        # @param expect [String] the commit it must still name
        # @return [String] the commit it names now
        # @raise [Moved] when the ref names another commit
        def move_ref(ref, to, expect:)
          raise Moved, "#{ref} is at #{@refs[ref]}, not #{expect}; nothing moved" unless @refs[ref] == expect

          @refs[ref] = to
        end

        # Points a ref at a commit whatever it named, as a forced update does.
        #
        # @param ref [String] the ref to write
        # @param to [String] the commit it should name
        # @return [String] the commit it names now
        def write_ref(ref, to)
          @refs[ref] = to
        end

        # Lands a branch on main in one move: merged onto the main that stands, never onto an
        # older one.
        #
        # @param name [String] the branch to land
        # @return [String] the commit main names now
        def land(name)
          before = tip(MAIN)
          move_ref(MAIN, merge(before, tip(name)), expect: before)
        end

        # @param old [String] the commit that may be held
        # @param young [String] the commit that may hold it
        # @return [Boolean] whether `young` is `old` or is built on it
        def ancestor?(old, young)
          seen = {}
          queue = [young]
          while (id = queue.shift)
            return true if id == old
            next if seen[id]

            seen[id] = true
            queue.concat(@parents.fetch(id, []))
          end
          false
        end
      end
    end
  end
end
