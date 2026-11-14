module Hecks
  module Bluebook
    module Merge
      # What each kind of conflict says happened.
      PHRASES = {
        both_changed:        "changed on both branches",
        removed_and_changed: "removed on one branch and changed on the other",
        both_added:          "added differently on both branches",
        unparsable:          "merged into text that does not parse"
      }.freeze

      # One member the two branches disagree on, named by what owns it. It holds the member's
      # text on the base and on each branch (nil where it is absent), so nothing a branch wrote
      # is lost when the merge stops.
      #
      # `owners` are the `[word, name]` of each declaration around the member, outermost first.
      Conflict = Struct.new(:kind, :owners, :word, :name, :named, :base, :ours, :theirs, keyword_init: true) do
        # @return [String, nil] the aggregate the member belongs to, or the aggregate itself
        def aggregate
          return name if word == "aggregate"

          owners.find { |owner_word, _| owner_word == "aggregate" }&.last
        end

        # The member's path: its owners from the aggregate down, then its name, as in
        # `Order.Place` or `Order.total`. Outside an aggregate the path starts below the file's
        # own declaration, and a member of the declaration itself is named by it.
        #
        # @return [String] the dotted path
        def subject
          from = owners.index { |owner_word, _| owner_word == "aggregate" } || [owners.size - 1, 1].min
          path = owners.drop(from).map(&:last)
          path << name if named
          path.compact.join(".")
        end

        # @return [String] the conflict in one line, as
        #   `Order.total: attribute changed on both branches`
        def to_s
          what = named || name.nil? ? word : "#{word} #{name.inspect}"
          [subject, "#{what} #{PHRASES.fetch(kind)}"].reject(&:empty?).join(": ")
        end
      end
    end
  end
end
