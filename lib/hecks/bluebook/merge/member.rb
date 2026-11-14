module Hecks
  module Bluebook
    module Merge
      # One declaration of a bluebook, hecksagon or world file as the text it was written in: the
      # word that declares it, the name it goes by, and either its whole text or, for a block laid
      # out over several lines, the members inside it.
      #
      # `lead` is the blank lines and loose comments above it; the comment lines directly above a
      # declaration are part of its `head`, so they travel with it. A member with `children` reads
      # `head` (through the line that opens the block), each child, `tail` (what follows the last
      # child) and `foot` (the closing line); one without holds all its text in `head`.
      Member = Struct.new(:word, :name, :named, :lead, :head, :children, :tail, :foot, keyword_init: true) do
        # @return [String] the member's own text, without its lead
        def text
          return head unless children

          "#{head}#{children.sum("") { |child| child.lead + child.text }}#{tail}#{foot}"
        end

        # What a member is matched by among its siblings. A named member (`command "Place"`,
        # `attribute :total`) is matched by word and name; any other (`role`, `invariant`,
        # `attaches`) by its word alone, and then by where it stands.
        #
        # @return [Array] `[word, name]` or `[word]`
        def group = named ? [word, name] : [word]

        # @return [Array(String, String)] the word and name a conflict reports an owner by
        def label = [word, name]
      end
    end
  end
end
