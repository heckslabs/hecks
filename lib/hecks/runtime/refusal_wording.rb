module Hecks
  module Runtime
    # Every DomainRefusal wording that is not already data — `given`/
    # `ensures`/a declared `invariant` already carry their own description,
    # read at dispatch time off the command or value object that declared
    # them. These are different in kind: LANGUAGE-LEVEL refusals, the same
    # wording for every domain, not authored per-bluebook.
    #
    # Declared the same way in Vocabulary::RefusalTemplate
    # (language/bluebook/vocabulary.bluebook) — spec/refusal_wording_
    # conformance_spec holds this table equal to the language, both
    # directions. Hand-typed rather than read live off the meta-domain at
    # every dispatch, the same reason Expression::Evaluator::
    # SIGN_TEST_OPERATORS is hand-typed beside Vocabulary::SignTest.
    module RefusalWording
      # `Layout/HashAlignment`'s repo-wide `table` style (.rubocop.yml)
      # would force every template string below onto the SAME column —
      # matching the widest key — leaving the longer wordings almost no
      # room to wrap under Layout/LineLength's own 130-column limit.
      # Disabled for exactly this one hash literal (a single statement, so
      # disable-next rather than a disable/enable pair).
      # rubocop:disable-next Layout/HashAlignment
      TEMPLATES = {
        %w[NotFound creating_no_identity]             =>
        "{command} creates a {aggregate} — pass {identity}:",
        %w[AlreadyExists creating_duplicate]          =>
        "{command} creates a {aggregate} that already exists — {identity} {offered}",
        %w[AlreadyExists entity_duplicate]            =>
        "a {entity} already exists on {aggregate} — {identity} {offered}",
        %w[NotFound acting_no_identity]               =>
        "{command} acts on an existing {aggregate} — pass {identity}:",
        %w[NotFound record_missing]                   =>
        "no {aggregate} with {identity} {offered}",
        %w[NotFound entity_parent_no_identity]        =>
        "{command} acts on a {aggregate}'s {entity} — pass {identity}:",
        %w[UnknownVerb entity_unknown]                =>
        "{aggregate} has no entity {entity}",
        %w[NotFound entity_element_no_identity]       =>
        "{command} acts on one {entity} — pass {identity}:",
        %w[NotFound entity_element_missing]           =>
        "no {entity} with {identity} {wants} on {aggregate} {parent_id}",
        %w[NotFound reference_target_missing]         =>
        "no {target} with {heads} {key}",
        %w[NotFound read_model_reference_missing]     =>
        "no {aggregate} with reference {offered}",
        %w[TypeMismatch read_model_object_reference]  =>
        "{query} refused — a reference is an id, and {field} arrived as an object",
        %w[UnknownVerb no_query]                      =>
        "{aggregate} has no query {query}",
        %w[UnknownVerb entity_query_missing]          =>
        "{entity} has no query {query}",
        %w[UnknownVerb entity_holds_no_list]          =>
        "{aggregate} holds no list of {entity}",
        %w[UnknownVerb entity_no_command]             =>
        "{entity} has no command {command}",
        %w[UnknownVerb aggregate_no_command]          =>
        "{aggregate} has no command {command}",
        %w[UnknownVerb port_no_operation]             =>
        "{port} has no operation {operation}",
        %w[UnknownVerb no_domain]                     =>
        "no domain {domain} loaded (verb {verb})",
        %w[UnknownVerb no_read_model]                 =>
        "{domain} has no read model {query}",
        %w[UnknownVerb not_fully_qualified]           =>
        "{verb} is not a fully-qualified verb (Domain::Aggregate.Command)",
        %w[UnknownVerb no_aggregate]                  =>
        "{domain} has no aggregate {aggregate}",
        %w[LifecycleRefused transition_blocked]       =>
        "{command} refused — {field} is {current}, and {command} moves it only from {allowed}",
        %w[TypeMismatch value_object_shape]           =>
        "{name} is a {type} — pass its fields as an object, not {offered}",
        %w[TypeMismatch reference_as_object]          =>
        "{command} refused — a reference is an id, and {attribute} arrived as an object{known_by}",
        %w[TypeMismatch multi_field_scalar]           =>
        "{type} has multiple fields and cannot stand in for a scalar",
        %w[TypeMismatch composite_identity]           =>
        "{type} is a composite identity — an identity must have exactly one field",
        %w[TypeMismatch numeric_field]                =>
        "{type}.{field} expects {expected}, got {offered}",
        %w[TypeMismatch non_finite_field]             =>
        "{type}.{field} must be a finite number, got {offered}",
        %w[TypeMismatch pattern_mismatch]             =>
        "{type}.{field} must match {pattern}, got {offered}",
        %w[TypeMismatch arithmetic_amount]            =>
        "{op} of {target} needs an Integer, got {offered}",
        %w[TypeMismatch arithmetic_current]           =>
        "{op} of {target} needs an Integer {target}, got {offered}",
        %w[TypeMismatch arithmetic_shared_field]      =>
        "{op} of {target} needs a value object with one shared Integer field",
        %w[UnknownArgument unknown_args]              =>
        "{command} does not declare {unknown} — it takes {declared}",
        %w[AbsentArgument absent_args]                =>
        "{command} was not given {absent} — it takes {declared}",
        %w[InvariantViolation closed_set_member]      =>
        "{type} admits {admitted} — got {offered}",
        %w[InvariantViolation value_object_invariant] =>
        "{name} invariant violated — {description} (given {offered})",
        %w[InvariantViolation admits_declared_set]    =>
        "{name} admits {admits} — {admitted} — got {offered}",
        %w[InvariantViolation undeclared_set]         =>
        "{name} admits {admits}, which this chapter does not declare — a closed set is named Aggregate::SetName, and it must " \
        "be one the bluebook actually holds",
        %w[Unauthorized tenant_required]              =>
        "{query} declares authorize with tenant: {field} — pass {field}: to name which {field} this ask is scoped to",
        %w[Unauthorized role_mismatch]                =>
        "{command} refused — role: {role}, and the caller stated {caller_role}",
        %w[AttributeAbsent absent_read]               =>
        "{aggregate} {field} is absent on this record — declared, not optional, and added since it was written. Backfill it " \
        "in a translation (backfill :{field}, default: ...), or declare it optional: true",
        %w[ProjectionAbsent absent_read]              =>
        "{aggregate} {field} is not yet projected on this record — declared via projects :{field}, but no rebuild sweep has " \
        "populated it. Run the sweep, or read {reference}.{remote_field} directly if this rule cannot wait"
      }.freeze

      module_function

      # Plain text substitution, never expression syntax — a template is
      # read, not evaluated. `render` computes the placeholder VALUES via
      # whatever the call site already had (a joined list, a rendered
      # identity reading, …) and this only replaces the markers.
      def render(refusal, site, **values)
        template = TEMPLATES.fetch([refusal, site]) do
          raise KeyError, "no refusal template for #{refusal}/#{site} — declare it in " \
                          "Vocabulary::RefusalTemplate first"
        end
        values.reduce(template) { |text, (key, value)| text.gsub("{#{key}}", value.to_s) }
      end
    end
  end
end
