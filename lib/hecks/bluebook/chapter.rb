require_relative "behaviour/chapter"
require_relative "capabilities"
require_relative "../ir"

module Hecks
  module Bluebook
    # The chapter, distinct from the `Bluebook` namespace it lives in.
    class Chapter
      include Construct
      include Behaviour::Chapter
      include Hecks::IR

      # The IR shape's own version — bump only when `to_h`'s shape changes,
      # not when a domain's declared `version:` does.
      IR_VERSION = 1

      emits_ir(
        ir_version:        -> { IR_VERSION },
        name:              :name,
        version:           :version,
        vision:            :vision,
        classification:    :classification,
        # Present (possibly nil) rather than silently absent, so two chapters
        # differing only by their old name can't hash identically at the
        # meta-validator's cache key (`SHA256(JSON(bluebook.to_h))`).
        formerly_known_as: :formerly_known_as,
        # The Ruby module the chapter's constants install under, when it is not the chapter's
        # own name (the Hecks domain nests under `Hecks::Domain`); nil for every other chapter.
        namespace:         :namespace,
        aggregates:        many(:aggregates),
        read_models:       many(:read_models),
        policies:          many(:policies),
        process_managers:  many(:process_managers),
        attaches_to:       :attaches_to,
        # One row per declared `provides` capability, in declaration order;
        # present (possibly empty) like `attaches_to`.
        provides:          -> { provides.map(&:to_h) },
        canonical_form:    -> { Expression::CanonicalForm.table }
      )

      # One row of a declared capability — `verb` is chapter-local;
      # `Behaviour::Chapter#provided_verb` qualifies it with the chapter's own name.
      Provision = Struct.new(:capability, :key, :verb, keyword_init: true) do
        # Coerces one declared or reconstructed `provides` row into a `Provision`.
        #
        # @param row [Bluebook::Chapter::Provision, #to_h] a `Provision` already, or
        #   anything answering `to_h` with `capability`/`key`/`verb` entries
        # @return [Bluebook::Chapter::Provision] `row` itself if it already is one, else
        #   a new `Provision` built from its fields
        def self.from(row)
          return row if row.is_a?(self)

          fields = row.to_h.transform_keys(&:to_sym)
          new(capability: fields[:capability].to_s, key: fields[:key].to_s, verb: fields[:verb].to_s)
        end
      end

      attr_reader :name, :version, :vision, :aggregates, :policies, :process_managers,
                  :classification, :read_models, :ports, :formerly_known_as, :namespace, :attaches_to, :provides

      # @param policies [Array<Bluebook::Policy>] every reaction declared across the
      #   chapter's own aggregates, hoisted here
      # @param classification [String, Symbol, nil] whether this chapter is central to
      #   its project's own domain model, or `nil` if undeclared
      def initialize(name:, version: nil, vision: nil, aggregates: [], policies: [],
                     process_managers: [], classification: nil, read_models: [], formerly_known_as: nil,
                     namespace: nil, attaches_to: [], provides: [])
        @policies         = policies
        @process_managers = process_managers
        @name       = name.to_s
        @hecks_name = @name
        @hecks_root = true
        @version    = version&.to_s
        @vision     = vision
        @aggregates = aggregates
        @read_models = read_models
        @classification = classification&.to_s
        @formerly_known_as = formerly_known_as&.to_s
        @namespace   = namespace&.to_s
        @attaches_to = Array(attaches_to).map(&:to_s)
        @provides    = Array(provides).map { |row| Provision.from(row) }
        settle
      end
    end
  end
end
