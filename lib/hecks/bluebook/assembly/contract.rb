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
      # Naming a field derived is a claim, and a claim needs a kind, not just a name
      # in a list. A bare list of names is a promise with nobody holding it: the
      # coverage gate only asks whether a field is accounted for, so `derived:
      # %i[version]` would satisfy it while dropping a chapter's version in
      # silence — the exact shape of every defect this arc has found.
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
        # @param key [String, Symbol] the field's declaration key, as `fields` names it
        # @return [Symbol, Array, nil] the reader named in `reads` for `key`, or `nil`
        #   when the field reads through the default single-cell reader
        def reader(key) = Hash(reads)[key.to_sym]

        # How an appendable list becomes rows the walk can offer. A list absent from
        # here reads straight off the node ; one that is present names the shaper,
        # because the IR keeps a shape the language does not — a transition whose
        # `from` is a list is several rows, an append binds several fields at once,
        # an open map is one row per entry.
        #
        # @param list [String, Symbol] the appendable list's field name
        # @return [Symbol, nil] the shaper method named in `rows` for `list`, or `nil`
        #   when the list reads straight off the node instead
        def shaper(list) = Hash(rows)[list.to_sym]

        # Whether `field` is one this contract accounts for, stored or derived.
        #
        # @param field [Symbol] the field name to check
        # @return [Boolean] whether `field` is a key of `fields` or of `derived`
        def declares?(field) = fields.key?(field) || derived.key?(field)

        # Names the kind of derived claim `field` makes, if any.
        #
        # @param field [Symbol] the derived field name to check
        # @return [Symbol, Array, nil] the kind `derived` names for `field` — `:parent`,
        #   `:children`, `:elsewhere`, `:walk`, an `[:computed, method]` or `[:folded,
        #   object, member]` pair — or `nil` when `field` is not derived
        def kind_of(field) = derived[field]

        # The fields the walk supplies — every `derived: { field => :walk }` claim.
        # The language declares them (`attribute :position, Position`) so the
        # judge can order siblings, but no constructor takes one. This is the one
        # place that fact is stated ; `Specializer` and `Model::Deviations` read it
        # here rather than each keeping their own `%i[position]`.
        #
        # @return [Array<Symbol>] every field name whose derived kind is `:walk`
        def walked = derived.select { |_field, kind| kind == :walk }.keys

        # Where a folded field actually lives, as [object, member].
        #
        # `[:folded, :lifecycle, :field]` says the language's `state_field` is the
        # `field` of the IR's one Lifecycle. `Readings` would otherwise have to state
        # that fact a second time as `node.lifecycle&.field` — saying it once here
        # drives both directions instead: the walk reads the member on the way in, and
        # the reconstruction gathers the members back into the object on the way out.
        #
        # A nil member means the fold has no single member to name — `rows` is a
        # count of what `closed_set` and `members` hold between them, and `options`
        # spreads across eight keys. Those keep their own code, and the gate still
        # checks the object they name is real.
        #
        # @param field [Symbol] the derived field name to check
        # @return [Array(Symbol, Symbol), Array(Array<Symbol>, nil), nil] the `[object,
        #   member]` pair the field folds into — `member` is `nil` when the fold has
        #   no single member to name — or `nil` when `field` does not fold at all
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
        # @param method [Symbol] the field name to check
        # @return [Boolean] whether `holder` answers `method` but its constructor does
        #   not accept it as a keyword
        def computes?(method)
          return false unless holder
          return false unless answers?(method)

          !accepts?(method)
        end

        # Whether `holder` answers `method`, checked the way that fits how it is
        # built: `respond_to?` for a `:declare` holder (a class, queried live) and
        # `method_defined?` for a `:new` holder (an instance method, checked without
        # building one).
        #
        # @param method [Symbol] the method name to check
        # @return [Boolean] whether `holder` answers `method`
        def answers?(method)
          make == :declare ? holder.respond_to?(method) : holder.method_defined?(method)
        end

        # Whether the holder's constructor takes `keyword` as a keyword argument.
        #
        # @param keyword [Symbol] the keyword to check
        # @return [Boolean] whether the holder's constructor (`.declare` or
        #   `#initialize`) accepts `keyword` as an optional or required keyword
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
      # `shape` and `handler` are not on this list — S17 (ADR 0026) made Member and
      # Dispatch nested entities, so neither is a parent field any more the way
      # `owner` is. `spec/assembly_spec` derives this set from `Plan` and the
      # contracts directly and fails on any drift, rather than trusting this list to
      # stay in sync with a second hand-written copy kept by the model generator.
      PARENT_POINTERS = %i[aggregate bluebook owner].freeze

      # Whether `field` is a parent pointer that does not end in `_id`.
      #
      # @param field [String, Symbol] the field name to check
      # @return [Boolean] whether `field` ends with `_id`, or is one of
      #   `PARENT_POINTERS`
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

      # Whether `field` is allow-listed as describing something other than
      # `category`'s own construct — see `ELSEWHERE`.
      #
      # @param category [String, Symbol] the construct category name
      # @param field [Symbol] the field name to check
      # @return [Boolean] whether `field` is on `category`'s `ELSEWHERE` entry
      def self.elsewhere?(category, field)
        Array(ELSEWHERE[category.to_sym]).include?(field)
      end
    end
  end
end
