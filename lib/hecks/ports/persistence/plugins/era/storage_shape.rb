require "json"
require "digest"

module Hecks
  module Runtime
    # The storage-shape projection of a bluebook: exactly the parts of
    # the IR that decide what persisted data looks like — aggregates,
    # their attributes (with full value-object/entity structure and
    # cardinality), references, the lifecycle field, and the identity
    # paths. Everything behavioral — commands, invariants, queries,
    # policies, lifecycle transitions, defaults, descriptions, comments,
    # the declared routing `version:` — is excluded, so editing behavior
    # never bumps an era and editing shape always does.
    #
    # ## Constraints left out on purpose
    #
    # Three attribute facts on the wire are constraints on persisted
    # values, not behavior, and are still excluded — each decided, not
    # overlooked:
    #
    #   `optional`  — required-ness is enforced at dispatch; stored rows
    #                 are never re-validated on read, so flipping it
    #                 strands nothing already written. Excluded.
    #   `pattern`   — same argument: a fact about what may be written
    #                 next, not about what was stored. Excluded.
    #   `admits`    — the sharpest of the three: narrowing a closed set
    #                 can strand stored rows outside it, and the wire
    #                 carries only the set's name, so a set whose members
    #                 changed under a stable name is invisible even to a
    #                 projection that included the fact (the same lesson
    #                 recursive value-object drift taught). Excluded, and
    #                 named as a gap: constraint tightening has no
    #                 translation-rule vocabulary to acknowledge it yet,
    #                 so including it would mint era bumps nothing can
    #                 explain. When the translation language grows a
    #                 constraint-acknowledgment rule, `admits` (by member
    #                 list, not by name) is first in line, and that
    #                 change bumps `FORM_VERSION`.
    #
    # ## Structural comparison over the dump form
    #
    # Projection runs over the canonical dump form (`to_h`, JSON
    # round-tripped), so a verdict depends only on the IR — never on live
    # object graphs. Structural comparison only, never a hash comparison.
    module StorageShape
      module_function

      # Reduces a bluebook to the parts of its IR that decide what stored data looks like.
      #
      # @param bluebook [Bluebook::Chapter] the bluebook whose `to_h` dump is projected
      # @return [Hash{String => Object}] `"name"` (the bluebook's name) and `"aggregates"`, an
      #   Array of the Hashes `project_aggregate` builds, sorted by aggregate name
      def project(bluebook)
        domain = JSON.parse(JSON.generate(bluebook.to_h))
        {
          "name"       => bluebook.name,
          "aggregates" => (domain["aggregates"] || [])
                          .map { |aggregate| project_aggregate(aggregate) }
                          .sort_by { |aggregate| aggregate["name"] }
        }
      end

      # Compares two bluebooks by storage shape alone, ignoring every behavioral difference.
      #
      # @param held [Bluebook::Chapter] the bluebook a held era was minted from
      # @param current [Bluebook::Chapter] the bluebook booting now
      # @return [Boolean] true when both project to an equal structure
      def same?(held, current) = project(held) == project(current)

      # The canonical serialization the Ruby scaffold hashes at mint time
      # — the one moment identity is computed. Nothing ever recomputes a
      # stored era name to verify it, so this form can evolve freely.
      #
      # @param bluebook [Bluebook::Chapter] the bluebook to serialize
      # @return [String] compact JSON text of `project(bluebook)`
      def canonical(bluebook) = JSON.generate(project(bluebook))

      # Computes the era identity of a bluebook's storage shape.
      #
      # @param bluebook [Bluebook::Chapter] the bluebook being minted
      # @return [String] 64 lowercase hex characters, the SHA-256 of `canonical(bluebook)`
      def mint_hash(bluebook) = Digest::SHA256.hexdigest(canonical(bluebook))

      LABEL_LENGTH = 6

      # Shortens the era identity to the label translation edges and refusals use.
      #
      # @param bluebook [Bluebook::Chapter] the bluebook being minted
      # @return [String] the first `LABEL_LENGTH` hex characters of `mint_hash(bluebook)`
      def mint_label(bluebook) = mint_hash(bluebook)[0, LABEL_LENGTH]

      # The version of the canonical serialization above. Minted-once
      # means a stored name stays valid across form changes — but only
      # if each name records which form minted it, so v1-named and
      # v2-named eras coexist legibly. Stored beside every minted hash
      # (names.tsv fourth field / hecks_eras.canon_form); bump this in
      # the same change that alters project/canonical output.
      FORM_VERSION = 1

      # Projects one dumped aggregate down to its identity, lifecycle field and attributes.
      #
      # @param aggregate [Hash{String => Object}] one entry of the dumped bluebook's
      #   `"aggregates"` list, string-keyed after the JSON round-trip
      # @return [Hash{String => Object}] `"name"`, `"identity"` (Array<String> of declared
      #   identity paths, `[]` when none is declared), `"lifecycle_field"` (String, or nil
      #   without a lifecycle) and `"attributes"` (Array of `project_attribute` Hashes, sorted
      #   by name)
      def project_aggregate(aggregate)
        {
          "name"            => aggregate["name"],
          # The declared identity paths, as a list, in declaration order —
          # order is semantic (the paths join in order to form the id).
          # No "id" fallback: an aggregate that declares nothing has [],
          # and that is a real declared state, distinct from an aggregate
          # identified by a field named "id".
          "identity"        => Array(aggregate["identified_by"]).map(&:to_s),
          "lifecycle_field" => aggregate.dig("lifecycle", "field"),
          "attributes"      => (aggregate["attributes"] || [])
                               .map { |attribute| project_attribute(aggregate, attribute, []) }
                               .sort_by { |attribute| attribute["name"] }
        }
      end

      # Projects one dumped attribute to its name, cardinality and full type signature.
      #
      # @param aggregate [Hash{String => Object}] the dumped aggregate that owns the attribute,
      #   searched for the value objects and entities its type may name
      # @param attribute [Hash{String => Object}] the dumped attribute, read for `"name"`,
      #   `"list"` and `"type"`
      # @param seen [Array<String>] type names already being expanded, which stops a
      #   self-referencing type from recursing forever
      # @return [Hash{String => Object}] `"name"` (String), `"list"` (Boolean) and `"type"`
      #   (whatever `type_signature` returns)
      def project_attribute(aggregate, attribute, seen)
        {
          "name" => attribute["name"].to_s,
          "list" => attribute["list"] ? true : false,
          "type" => type_signature(aggregate, attribute["type"].to_s, seen)
        }
      end

      # A plain type name for a primitive; the type name plus its
      # members' full signatures for a value object or entity — so two
      # attributes with the same declared type name but different
      # internals are never mistaken for unchanged.
      #
      # @param aggregate [Hash{String => Object}] the dumped aggregate whose value objects and
      #   entities are searched for `type_name`
      # @param type_name [String] the attribute's declared type name
      # @param seen [Array<String>] type names already being expanded
      # @return [String, Hash{String => Object}] `type_name` itself for a primitive or a type
      #   already in `seen`; otherwise `"type"` plus `"members"`, the member attributes'
      #   `project_attribute` Hashes sorted by name
      def type_signature(aggregate, type_name, seen)
        container = nested_type(aggregate, type_name)
        return type_name if container.nil? || seen.include?(type_name)

        {
          "type"    => type_name,
          "members" => (container["attributes"] || [])
                       .map { |member| project_attribute(aggregate, member, seen + [type_name]) }
                       .sort_by { |member| member["name"] }
        }
      end

      # Looks a type name up among a dumped aggregate's value objects, then its entities.
      #
      # @param aggregate [Hash{String => Object}] the dumped aggregate to search
      # @param type_name [String] the declared type name to find
      # @return [Hash{String => Object}, nil] the dumped value object or entity; nil when the
      #   name is a primitive or belongs to nothing this aggregate declares
      def nested_type(aggregate, type_name)
        (aggregate["value_objects"] || []).find { |vo| vo["name"] == type_name } ||
          (aggregate["entities"] || []).find { |entity| entity["name"] == type_name }
      end
    end
  end
end
