module Hecks
  module Bluebook
    # The rulebook translating between the language's own declarations and the
    # IR objects `Build`/`Reconstruction` produce from them — the `Contract`
    # struct format itself (this file) plus, reopened in contracts.rb, the
    # `CONTRACTS` table of one `Contract` per construct category.
    class Assembly
      # What a construct needs that the language cannot say, and how a claim that a
      # field needs no assembling is checked.
      #
      # `derived:` names a kind for each claim rather than listing bare field names —
      # a bare list of names is a promise with nobody holding it. A coverage gate
      # that only asks whether a field is accounted for would let `derived:
      # %i[version]` satisfy it while a chapter's version silently drops, which is
      # the exact shape of every defect this arc has found. Naming a field derived
      # is a claim, and a claim needs a kind:
      #
      #   :parent            the containment tree supplies it — a `*_id`, or one of
      #                      the named pointers below. Checked against the name.
      #   :children          it is assembled as child constructs. Checked against the
      #                      language: a category must exist whose parent is this one.
      #   [:computed, :m]    the holder works it out. Checked: it must answer to `m`.
      #   [:folded, keys]    several language fields are one thing in the IR, or one
      #                      is spread across several. Checked: every key must appear
      #                      in a real reconstructed declaration.
      #   :elsewhere         not a fact about this construct at all. Allow-listed one
      #                      by one, because it is the kind with no other check.
      #
      # Every one of those can fail. That is the whole difference.
      Contract = Struct.new(:holder, :make, :fields, :derived, :rows, :reads, keyword_init: true) do
        # How a declaration key is read back off a row. Absent means the default —
        # `text(row[key])`, a single cell — which is most of them ; present names the
        # shape, because a list needs a reader per element and a folded field is
        # gathered rather than fetched. Same pattern as `rows`, in the other
        # direction: declare the exceptions, default the rest.
        #
        # @param key [Symbol] the declaration key to look up a reader for
        # @return [Symbol, Array, nil] the reader spec `Build.read` decodes (`:plain`,
        #   `:identity`, `:flag`, `[:each, marks_method]`, `[:option, name]`, or a bare
        #   `Marks` method name), or `nil` for the default single-cell reader
        def reader(key) = Hash(reads)[key.to_sym]

        # How an appendable list becomes rows the walk can offer. A list absent from
        # here reads straight off the node ; one that is present names the shaper,
        # because the IR keeps a shape the language does not — a transition whose
        # `from` is a list is several rows, an append binds several fields at once,
        # an open map is one row per entry.
        #
        # @param list [Symbol] the list field's name
        # @return [Symbol, nil] the `Marks` method that shapes `list`'s rows, or `nil`
        #   to read the list straight off the node
        def shaper(list) = Hash(rows)[list.to_sym]

        # Says whether this contract's construct declares a field.
        #
        # @param field [Symbol] the field to check
        # @return [Boolean] whether this contract's construct declares `field`, either
        #   as a language field or as a derived claim
        def declares?(field) = fields.key?(field) || derived.key?(field)

        # Looks up the derived kind claimed for a field.
        #
        # @param field [Symbol] the field to look up
        # @return [Symbol, Array, nil] the derived kind claimed for `field` — `:parent`,
        #   `:children`, `[:computed, method]`, `[:folded, keys]`, `:elsewhere`, `:walk` —
        #   or `nil` if `field` is not a derived claim
        def kind_of(field) = derived[field]

        # The fields the walk supplies — every `derived: { field => :walk }` claim.
        # The language declares them (`attribute :position, Position`) so the
        # judge can order siblings, but no constructor takes one. This is the one
        # place that fact is stated ; `Specializer` and `Model::Deviations` read it
        # here rather than each keeping their own `%i[position]`.
        #
        # @return [Array<Symbol>] every field this contract claims the walk supplies
        def walked = derived.select { |_field, kind| kind == :walk }.keys

        # Where a folded field actually lives, as [object, member].
        #
        # `[:folded, :lifecycle, :field]` says the language's `state_field` is the
        # `field` of the IR's one Lifecycle. That is the same fact `Readings` would
        # otherwise have to state a second time as `node.lifecycle&.field` — saying it
        # once here drives both directions: the walk reads the member on the way in,
        # and the reconstruction gathers the members back into the object on the way
        # out.
        #
        # A nil member means the fold has no single member to name — `rows` is a
        # count of what `closed_set` and `members` hold between them, and `options`
        # spreads across eight keys. Those keep their own code, and the gate still
        # checks the object they name is real.
        #
        # @param field [Symbol] the field to look up
        # @return [Array(Symbol, Symbol), nil] `[holder_field, member]` naming where a
        #   folded field actually lives, or `nil` if `field` is not a `:folded` claim
        def folded(field)
          kind = derived[field]
          return nil unless kind.is_a?(Array) && kind.first == :folded

          [kind[1], kind[2]]
        end

        # Computed means worked out, not merely answerable.
        #
        # Asking only whether the holder responds was too weak, and measurably so:
        # `[:computed, :version]` passed, because `Bluebook` does answer to
        # `version` — it just answers with what the constructor was handed. A field
        # the constructor takes is stored, and calling it computed is how a chapter's
        # version would have gone missing while the gate said yes.
        #
        # So a computed field is one the holder answers and the constructor does not
        # accept. `query_name` qualifies (`Naming.snake(name)`) ; `version` cannot.
        #
        # @param method [Symbol] the field's name, asked as a method
        # @return [Boolean] whether the holder answers `method` but its constructor
        #   does not accept it as a keyword
        def computes?(method)
          return false unless holder
          return false unless answers?(method)

          !accepts?(method)
        end

        # Says whether the holder answers a method at all.
        #
        # @param method [Symbol] the method name to check
        # @return [Boolean] whether the holder (its class, for `:declare`; its
        #   instances, for `:new`) responds to `method`
        def answers?(method)
          make == :declare ? holder.respond_to?(method) : holder.method_defined?(method)
        end

        # Says whether the holder's builder accepts a keyword argument.
        #
        # @param keyword [Symbol] the keyword to check
        # @return [Boolean] whether the holder's builder (`.declare` or `#initialize`)
        #   accepts `keyword` as a required or optional keyword argument
        def accepts?(keyword)
          builder = make == :declare ? holder.method(:declare) : holder.instance_method(:initialize)

          builder.parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == keyword }
        end
      end

      # The fields that point at a parent without being spelled `*_id` — the one list,
      # read by the assembly gate (a `:parent` claim), the model generator and
      # QueryIR (a declared field the model composes instead of storing).
      #
      #   aggregate, bluebook   the bare parent link a creating command mints
      #                         (ADR 0025) — exactly the `parent_key`s `Plan` reads
      #                         off the language
      #   owner                 Entity's own text twin of that link, which is why
      #                         Entity's contract claims `owner: :parent`
      #
      # A hand-maintained list here that drifts from the model's own copy is a
      # silent failure mode this arc has already found once: `shape` and `handler`
      # were Member's and Dispatch's own parent fields before S17 (ADR 0026) made
      # both nested entities, and nothing noticed the two lists had stopped
      # agreeing. spec/assembly_spec now derives this set from `Plan` and the
      # contracts instead, and fails on any drift.
      PARENT_POINTERS = %i[aggregate bluebook owner].freeze

      # Says whether a field is a bare pointer at a parent construct.
      #
      # @param field [Symbol, String] the field to check
      # @return [Boolean] whether `field` is a bare parent pointer — named in
      #   `PARENT_POINTERS`, or ending in `_id`
      def self.parent_pointer?(field)
        field.to_s.end_with?("_id") || PARENT_POINTERS.include?(field.to_sym)
      end

      # The only fields allowed to claim they describe something other than the
      # construct they hang off, each with the reason spelled out.
      #
      #   normalisations   the canonical-form table belongs to the expression grammar.
      #                    A chapter's rules are canonicalised on the way in, so the
      #                    language models the table — but no chapter stores one, and
      #                    `Bluebook#to_h` splices it in from Expression.
      ELSEWHERE = {
        Bluebook: %i[normalisations]
      }.freeze

      # Says whether a field is allow-listed to describe something other than its
      # own construct.
      #
      # @param category [Symbol, String] the construct category's name
      # @param field [Symbol] the field to check
      # @return [Boolean] whether `field` is allow-listed as `:elsewhere` for `category`
      def self.elsewhere?(category, field)
        Array(ELSEWHERE[category.to_sym]).include?(field)
      end
    end
  end
end
