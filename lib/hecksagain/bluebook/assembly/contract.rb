module Hecksagain
  module Bluebook
    class Assembly
      # WHAT A CONSTRUCT NEEDS THAT THE LANGUAGE CANNOT SAY, and how a claim that a
      # field needs no assembling is CHECKED.
      #
      # `derived:` used to be a list of names, and a list of names is a promise with
      # nobody holding it. The coverage gate only asked whether a field was accounted
      # for — so writing `derived: %i[version]` would have satisfied it while dropping
      # a chapter's version in silence, which is the exact shape of every defect this
      # arc has found. Naming a field derived is a CLAIM, and a claim needs a kind:
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
      # Every one of those can FAIL. That is the whole difference.
      Contract = Struct.new(:holder, :make, :fields, :derived, :rows, :reads, keyword_init: true) do
        # How a declaration key is read back off a ROW. Absent means the default —
        # `text(row[key])`, a single cell — which is most of them ; present names the
        # shape, because a list needs a reader per element and a folded field is
        # gathered rather than fetched. Same pattern as `rows`, in the other
        # direction: declare the exceptions, default the rest.
        def reader(key) = Hash(reads)[key.to_sym]

        # How an appendable LIST becomes rows the walk can offer. A list absent from
        # here reads straight off the node ; one that is present names the shaper,
        # because the IR keeps a shape the language does not — a transition whose
        # `from` is a list is several rows, an append binds several fields at once,
        # an open map is one row per entry.
        def shaper(list) = Hash(rows)[list.to_sym]

        def declares?(field) = fields.key?(field) || derived.key?(field)

        def kind_of(field) = derived[field]

        # WHERE A FOLDED FIELD ACTUALLY LIVES, as [object, member].
        #
        # `[:folded, :lifecycle, :field]` says the language's `state_field` is the
        # `field` of the IR's one Lifecycle. That is the same fact `Readings` used to
        # state a second time as `node.lifecycle&.field` — so saying it once here
        # drives BOTH directions: the walk reads the member on the way in, and the
        # reconstruction gathers the members back into the object on the way out.
        #
        # A nil member means the fold has no single member to name — `rows` is a
        # count of what `closed_set` and `members` hold between them, and `options`
        # spreads across eight keys. Those keep their own code, and the gate still
        # checks the object they name is real.
        def folded(field)
          kind = derived[field]
          return nil unless kind.is_a?(Array) && kind.first == :folded

          [kind[1], kind[2]]
        end

        # COMPUTED means worked out, not merely answerable.
        #
        # Asking only whether the holder responds was too weak, and measurably so:
        # `[:computed, :version]` passed, because `Bluebook` does answer to
        # `version` — it just answers with what the constructor was handed. A field
        # the constructor TAKES is stored, and calling it computed is how a chapter's
        # version would have gone missing while the gate said yes.
        #
        # So a computed field is one the holder answers AND the constructor does not
        # accept. `query_name` qualifies (`Naming.snake(name)`) ; `version` cannot.
        def computes?(method)
          return false unless holder
          return false unless answers?(method)

          !accepts?(method)
        end

        def answers?(method)
          make == :declare ? holder.respond_to?(method) : holder.instance_methods.include?(method)
        end

        def accepts?(keyword)
          builder = make == :declare ? holder.method(:declare) : holder.instance_method(:initialize)

          builder.parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == keyword }
        end
      end

      # The fields that hold a parent's id without being spelled `*_id`. An entity is
      # declared in an aggregate, a member on a value object, a dispatch inside a
      # handler, and each names its parent with a word rather than a suffix.
      PARENT_POINTERS = %i[owner shape handler].freeze

      # The only fields allowed to claim they describe something other than the
      # construct they hang off, each with the reason spelled out.
      #
      #   normalisations   the canonical-form table belongs to the expression grammar.
      #                    A chapter's rules are canonicalised on the way in, so the
      #                    language models the table — but no chapter STORES one, and
      #                    `Bluebook#to_h` splices it in from Expression.
      ELSEWHERE = {
        Bluebook: %i[normalisations]
      }.freeze

      def self.elsewhere?(category, field)
        Array(ELSEWHERE[category.to_sym]).include?(field)
      end
    end
  end
end
