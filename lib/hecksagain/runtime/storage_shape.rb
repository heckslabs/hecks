require "json"
require "digest"

module Hecksagain
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
    # Three attribute facts on the wire are constraints on PERSISTED
    # VALUES, not behavior, and are still excluded — each decided, not
    # overlooked:
    #
    #   `optional`  — required-ness is enforced at dispatch; stored rows
    #                 are never re-validated on read, so flipping it
    #                 strands nothing already written. Excluded.
    #   `pattern`   — same argument: a fact about what may be WRITTEN
    #                 next, not about what was stored. Excluded.
    #   `admits`    — the sharpest of the three: narrowing a closed set
    #                 CAN strand stored rows outside it, and the wire
    #                 carries only the set's NAME, so a set whose members
    #                 changed under a stable name is invisible even to a
    #                 projection that included the fact (the same lesson
    #                 recursive value-object drift taught). Excluded, and
    #                 NAMED as a gap: constraint tightening has no
    #                 translation-rule vocabulary to acknowledge it yet,
    #                 so including it would mint era bumps nothing can
    #                 explain. When the translation language grows a
    #                 constraint-acknowledgment rule, `admits` (by member
    #                 list, not by name) is first in line, and that
    #                 change bumps FORM_VERSION.
    #
    # Projection runs over the canonical dump form (`to_h`, JSON
    # round-tripped), so a verdict depends only on the IR — never on live
    # object graphs. Structural comparison only, never a hash comparison.
    module StorageShape
      module_function

      def project(bluebook)
        domain = JSON.parse(JSON.generate(bluebook.to_h))
        {
          "name"       => bluebook.name,
          "aggregates" => (domain["aggregates"] || [])
                          .map { |aggregate| project_aggregate(aggregate) }
                          .sort_by { |aggregate| aggregate["name"] }
        }
      end

      def same?(held, current) = project(held) == project(current)

      # The canonical serialization the Ruby scaffold hashes at MINT time
      # — the one moment identity is computed. Nothing ever recomputes a
      # stored era name to verify it, so this form can evolve freely.
      def canonical(bluebook) = JSON.generate(project(bluebook))

      def mint_hash(bluebook) = Digest::SHA256.hexdigest(canonical(bluebook))

      LABEL_LENGTH = 6
      def mint_label(bluebook) = mint_hash(bluebook)[0, LABEL_LENGTH]

      # The version of the canonical serialization above. Minted-once
      # means a stored name stays valid across form changes — but only
      # if each name records WHICH form minted it, so v1-named and
      # v2-named eras coexist legibly. Stored beside every minted hash
      # (names.tsv fourth field / hecks_eras.canon_form); bump this in
      # the same change that alters project/canonical output.
      FORM_VERSION = 1

      def project_aggregate(aggregate)
        {
          "name"            => aggregate["name"],
          # The declared identity paths, AS A LIST, in declaration order —
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

      def nested_type(aggregate, type_name)
        (aggregate["value_objects"] || []).find { |vo| vo["name"] == type_name } ||
          (aggregate["entities"] || []).find { |entity| entity["name"] == type_name }
      end
    end
  end
end
