require_relative "behaviour/chapter"
require_relative "../ir"

module Hecks
  module Bluebook
    # THE CHAPTER, and no longer the namespace it lives in.
    #
    # `Hecks::Bluebook` was briefly a CLASS, because dropping the
    # old `IR::` segment would otherwise have produced
    # `Bluebook::Bluebook` — a class shadowing its own enclosing module.
    # Naming the construct what the code already called it everywhere
    # (a chapter; this file was already chapter.rb) removes the clash
    # at the source, so the namespace goes back to being a module.
    #
    # Measured before changing: `Bluebook` was used AS a class in five
    # places and as a namespace in seventy-seven files.
    class Chapter
      include Construct
      include Behaviour::Chapter
      include Hecks::IR

      # THE SCHEMA'S OWN VERSION — not a domain's `version:` (Banking's
      # "v1", a business fact the AUTHOR chose), but the shape `to_h`
      # itself emits. A consumer reading exported IR with no Ruby DSL to
      # cross-check against (a build-time generator, a stored snapshot)
      # needs to know WHICH shape it's holding before it can safely
      # interpret any of the rest of it. Bump this when `to_h`'s own
      # shape changes in a way a consumer would need to know about —
      # not when a domain's own declarations change.
      IR_VERSION = 1

      emits_ir(
        ir_version:        -> { IR_VERSION },
        name:              :name,
        version:           :version,
        vision:            :vision,
        classification:    :classification,
        # M10 — a domain rename (`formerly_known_as "OldName"`) drives a
        # real Postgres schema rename at boot (EraResolver reads
        # `bluebook.formerly_known_as` off the live Ruby object) and the
        # meta-validator's cache key is `SHA256(JSON(bluebook.to_h))` — so
        # a fact this method didn't spell was a fact two chapters
        # differing ONLY by their old name could hash identically on,
        # same as read-model filters before them. Spelled here for the
        # same reason `version`/`vision` are: a plain field, present
        # (possibly nil) rather than silently absent.
        formerly_known_as: :formerly_known_as,
        aggregates:        many(:aggregates),
        read_models:       many(:read_models),
        policies:          many(:policies),
        process_managers:  many(:process_managers),
        attaches_to:       :attaches_to,
        canonical_form:    -> { Expression::CanonicalForm.table }
      )

      attr_reader :name, :version, :vision, :aggregates, :policies, :process_managers,
                  :classification, :read_models, :ports, :formerly_known_as, :attaches_to

      def initialize(name:, version: nil, vision: nil, aggregates: [], policies: [],
                     process_managers: [], classification: nil, read_models: [], formerly_known_as: nil,
                     attaches_to: [])
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
        @attaches_to = Array(attaches_to).map(&:to_s)
        settle
      end
    end
  end
end
