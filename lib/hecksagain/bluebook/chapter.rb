require_relative "behaviour/chapter"

module Hecksagain
  # THE CHAPTER ITSELF. `Hecksagain::Bluebook` is a CLASS, and this is
  # its body — what used to be `Bluebook`, which named the
  # model after one of the things it emits. Everything else a bluebook
  # declares is nested under it (`Bluebook::Aggregate`, `Bluebook::Command`),
  # alongside the ways to build one (`Bluebook::DSL`) and to judge one
  # (`Bluebook::MetaValidator`). Same shape as `Net::HTTP` nesting
  # `Net::HTTP::Get`: a class is a perfectly good namespace.
  class Bluebook
    include Construct
    include Behaviour::Chapter
    include Hecksagain::IR

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
      ir_version:       -> { IR_VERSION },
      name:             :name,
      version:          :version,
      vision:           :vision,
      classification:   :classification,
      aggregates:       many(:aggregates),
      read_models:      many(:read_models),
      policies:         many(:policies),
      process_managers: many(:process_managers),
      canonical_form:   -> { Expression::CanonicalForm.table }
    )

    attr_reader :name, :version, :vision, :aggregates, :policies, :process_managers,
                :classification, :read_models, :ports, :formerly_known_as

    def initialize(name:, version: nil, vision: nil, aggregates: [], policies: [],
                   process_managers: [], classification: nil, read_models: [], formerly_known_as: nil)
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
      settle
    end

  end
end
