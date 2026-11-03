require_relative "behaviour/declaration"
require_relative "capabilities"
require_relative "keyword_fields"
require_relative "../ir"

module Hecks
  module Bluebook
    # The bluebook, distinct from the `Bluebook` namespace it lives in.
    class Declaration
      include Construct
      include Behaviour::Declaration
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
        # Present (possibly nil) rather than silently absent, so two bluebooks
        # differing only by their old name can't hash identically at the
        # meta-validator's cache key (`SHA256(JSON(bluebook.to_h))`).
        formerly_known_as: :formerly_known_as,
        # The Ruby module the bluebook's constants install under, when it is not the bluebook's
        # own name (the Hecks domain nests under `Hecks::Domain`); nil for every other bluebook.
        namespace:         :namespace,
        aggregates:        many(:aggregates),
        read_models:       many(:read_models),
        policies:          many(:policies),
        process_managers:  many(:process_managers),
        attaches_to:       :attaches_to,
        # One row per declared `provides` capability, in declaration order;
        # present (possibly empty) like `attaches_to`.
        provides:          -> { provides.map(&:to_h) },
        # One row per aggregate a module groups, in declaration order; left out when the bluebook
        # declares no module, so a bluebook that never groups emits as it did.
        modules:           -> { modules.empty? ? Hecks::IR::OMIT : modules.map(&:to_h) },
        canonical_form:    -> { Expression::CanonicalForm.table }
      )

      # One row of a declared capability — `verb` is bluebook-local;
      # `Behaviour::Bluebook#provided_verb` qualifies it with the bluebook's own name.
      Provision = Struct.new(:capability, :key, :verb, keyword_init: true) do
        # Coerces one declared or reconstructed `provides` row into a `Provision`.
        #
        # @param row [Bluebook::Declaration::Provision, #to_h] a `Provision` already, or
        #   anything answering `to_h` with `capability`/`key`/`verb` entries
        # @return [Bluebook::Declaration::Provision] `row` itself if it already is one, else
        #   a new `Provision` built from its fields
        def self.from(row)
          return row if row.is_a?(self)

          fields = row.to_h.transform_keys(&:to_sym)
          new(capability: fields[:capability].to_s, key: fields[:key].to_s, verb: fields[:verb].to_s)
        end
      end

      # One aggregate's membership of a module: the module's name and vision, and the aggregate.
      ModuleRow = Struct.new(:name, :vision, :aggregate, keyword_init: true) do
        # Coerces one declared or reconstructed module row into a `ModuleRow`.
        #
        # @param row [Bluebook::Declaration::ModuleRow, #to_h] a `ModuleRow` already, or anything
        #   answering `to_h` with `name`/`vision`/`aggregate` entries
        # @return [Bluebook::Declaration::ModuleRow] `row` itself if it already is one, else a new
        #   one
        def self.from(row)
          return row if row.is_a?(self)

          fields = row.to_h.transform_keys(&:to_sym)
          new(name: fields[:name].to_s, vision: fields[:vision].to_s, aggregate: fields[:aggregate].to_s)
        end
      end

      attr_accessor :formerly_known_as

      attr_reader :name, :version, :vision, :aggregates, :policies, :process_managers,
                  :classification, :read_models, :ports, :namespace, :attaches_to, :provides,
                  :modules

      # The sagas, under the language's word: the judge reads a `Saga` category's collection
      # by that name (ADR 0180). The IR key stays `process_managers` until its own slice moves
      # it on both sides of the Ruby/Rust comparison.
      #
      # @return [Array<Bluebook::ProcessManager>] every saga this bluebook declares
      def sagas = process_managers

      # Every optional field and what it holds when the declaration omits it.
      FIELD_DEFAULTS = {
        version: nil, vision: nil, aggregates: [], policies: [], process_managers: [],
        classification: nil, read_models: [], formerly_known_as: nil, namespace: nil,
        attaches_to: [], provides: [], modules: []
      }.freeze

      # @param policies [Array<Bluebook::Policy>] every reaction declared across the
      #   bluebook's own aggregates, hoisted here
      # @param classification [String, Symbol, nil] whether this bluebook is central to
      #   its project's own domain model, or `nil` if undeclared
      def initialize(name:, **given)
        KeywordFields.assign(self, KeywordFields.fill(given, FIELD_DEFAULTS))
        @name       = name.to_s
        @hecks_name = @name
        @hecks_root = true
        coerce_fields
        settle
      end

      # Holds every optional field as the text or rows its reader answers.
      def coerce_fields
        @version           = @version&.to_s
        @classification    = @classification&.to_s
        @formerly_known_as = @formerly_known_as&.to_s
        @namespace         = @namespace&.to_s
        coerce_rows
      end
      private :coerce_fields

      # Holds every row-valued field as the rows its reader answers.
      def coerce_rows
        @attaches_to = Array(@attaches_to).map(&:to_s)
        @provides    = Array(@provides).map { |row| Provision.from(row) }
        @modules     = Array(@modules).map { |row| ModuleRow.from(row) }
      end
      private :coerce_rows
    end
  end
end
