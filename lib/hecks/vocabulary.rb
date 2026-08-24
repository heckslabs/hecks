# GENERATED — projected from the language's own Vocabulary aggregate
# (lib/hecks/language/bluebook/vocabulary.bluebook).
#
# DO NOT EDIT. spec/vocabulary_table_spec.rb re-projects this in memory
# and refuses a diff, so an edit here fails the ordinary suite.
#
# Plain data on purpose — no requires, no dependency on the model —
# because several of these sets are read while a bluebook is still
# being parsed. A table that needed the framework to load could not
# be the table the framework loads with.

module Hecks
  module Vocabulary
    TABLES = {
      "AggregateDispatchOrder" => [
        {"step"=>"refuse_unknown_arguments"}.freeze,
        {"step"=>"refuse_absent_arguments"}.freeze,
        {"step"=>"normalize_args"}.freeze,
        {"step"=>"refuse_role_mismatch"}.freeze,
        {"step"=>"resolve_references"}.freeze,
        {"step"=>"hydrate"}.freeze,
        {"step"=>"enforce_givens"}.freeze,
        {"step"=>"admissible_transition"}.freeze,
        {"step"=>"assign_creation_attributes"}.freeze,
        {"step"=>"apply_mutations"}.freeze,
        {"step"=>"advance_lifecycle"}.freeze,
        {"step"=>"delegate_to_entity"}.freeze,
        {"step"=>"enforce_ensures"}.freeze,
        {"step"=>"enforce_invariants"}.freeze,
        {"step"=>"save"}.freeze,
        {"step"=>"emit"}.freeze
      ].freeze,
      "Comparison" => [
        {"symbol"=>">=", "compares_less_than"=>"true", "compares_equal"=>"false", "negated"=>"true"}.freeze,
        {"symbol"=>"<=", "compares_less_than"=>"true", "compares_equal"=>"true", "negated"=>"false"}.freeze,
        {"symbol"=>"<", "compares_less_than"=>"true", "compares_equal"=>"false", "negated"=>"false"}.freeze,
        {"symbol"=>">", "compares_less_than"=>"true", "compares_equal"=>"true", "negated"=>"true"}.freeze,
        {"symbol"=>"==", "compares_less_than"=>"false", "compares_equal"=>"true", "negated"=>"false"}.freeze,
        {"symbol"=>"!=", "compares_less_than"=>"false", "compares_equal"=>"true", "negated"=>"true"}.freeze
      ].freeze,
      "DomainRefusal" => [
        {"name"=>"AbsentArgument"}.freeze,
        {"name"=>"AlreadyExists"}.freeze,
        {"name"=>"AttributeAbsent"}.freeze,
        {"name"=>"EnsuresNotMet"}.freeze,
        {"name"=>"GivenNotMet"}.freeze,
        {"name"=>"InvariantViolation"}.freeze,
        {"name"=>"LifecycleRefused"}.freeze,
        {"name"=>"NotFound"}.freeze,
        {"name"=>"ProjectionAbsent"}.freeze,
        {"name"=>"RemoteRefusal"}.freeze,
        {"name"=>"TypeMismatch"}.freeze,
        {"name"=>"Unauthorized"}.freeze,
        {"name"=>"UnknownArgument"}.freeze,
        {"name"=>"UnknownVerb"}.freeze
      ].freeze,
      "EntityDispatchOrder" => [
        {"step"=>"normalize_args"}.freeze,
        {"step"=>"refuse_role_mismatch"}.freeze,
        {"step"=>"resolve_references"}.freeze,
        {"step"=>"hydrate_parent"}.freeze,
        {"step"=>"locate_element"}.freeze,
        {"step"=>"enforce_givens"}.freeze,
        {"step"=>"admissible_transition"}.freeze,
        {"step"=>"apply_mutations"}.freeze,
        {"step"=>"advance_lifecycle"}.freeze,
        {"step"=>"enforce_ensures"}.freeze,
        {"step"=>"enforce_invariants"}.freeze,
        {"step"=>"save"}.freeze,
        {"step"=>"emit"}.freeze
      ].freeze,
      "FieldHint" => [
        {"name"=>"email", "pattern"=>"email", "resolves_to"=>"html_type"}.freeze,
        {"name"=>"url", "pattern"=>"\\b(url|uri|website|link)\\b", "resolves_to"=>"html_type"}.freeze,
        {"name"=>"tel", "pattern"=>"phone|\\btel(ephone)?\\b", "resolves_to"=>"html_type"}.freeze,
        {"name"=>"textarea", "pattern"=>"\\b(text|body|note|notes|description|message|comment)\\b", "resolves_to"=>"kind"}.freeze
      ].freeze,
      "IncludeHaystack" => [
        {"type"=>"Array", "strategy"=>"membership"}.freeze,
        {"type"=>"String", "strategy"=>"substring"}.freeze
      ].freeze,
      "LoadOrder" => [
        {"glob"=>"*.port"}.freeze,
        {"glob"=>"*.adapter"}.freeze,
        {"glob"=>"*.bluebook"}.freeze,
        {"glob"=>"translations/*.bluebook"}.freeze,
        {"glob"=>"*.hecksagon"}.freeze,
        {"glob"=>"*.world"}.freeze
      ].freeze,
      "MutationOp" => [
        {"name"=>"set", "sign"=>""}.freeze,
        {"name"=>"append", "sign"=>""}.freeze,
        {"name"=>"increment", "sign"=>"1"}.freeze,
        {"name"=>"decrement", "sign"=>"-1"}.freeze,
        {"name"=>"multiply", "sign"=>""}.freeze,
        {"name"=>"clamp", "sign"=>""}.freeze,
        {"name"=>"remove", "sign"=>""}.freeze,
        {"name"=>"delegate", "sign"=>""}.freeze
      ].freeze,
      "NormalisationStrategy" => [
        {"name"=>"collapse_whitespace"}.freeze,
        {"name"=>"replace"}.freeze
      ].freeze,
      "Primitive" => [
        {"name"=>"String"}.freeze,
        {"name"=>"Integer"}.freeze,
        {"name"=>"Float"}.freeze,
        {"name"=>"TrueClass"}.freeze,
        {"name"=>"FalseClass"}.freeze
      ].freeze,
      "QueryComparator" => [
        {"name"=>"eq"}.freeze,
        {"name"=>"ne"}.freeze,
        {"name"=>"gt"}.freeze,
        {"name"=>"gte"}.freeze,
        {"name"=>"lt"}.freeze,
        {"name"=>"lte"}.freeze,
        {"name"=>"in"}.freeze,
        {"name"=>"contains"}.freeze,
        {"name"=>"none_in_state"}.freeze
      ].freeze,
      "RefusalTemplate" => [
        {"refusal"=>"NotFound", "site"=>"creating_no_identity", "template"=>"{command} creates a {aggregate} — pass {identity}:"}.freeze,
        {"refusal"=>"AlreadyExists", "site"=>"creating_duplicate", "template"=>"{command} creates a {aggregate} that already exists — {identity} {offered}"}.freeze,
        {"refusal"=>"AlreadyExists", "site"=>"entity_duplicate", "template"=>"a {entity} already exists on {aggregate} — {identity} {offered}"}.freeze,
        {"refusal"=>"NotFound", "site"=>"acting_no_identity", "template"=>"{command} acts on an existing {aggregate} — pass {identity}:"}.freeze,
        {"refusal"=>"NotFound", "site"=>"record_missing", "template"=>"no {aggregate} with {identity} {offered}"}.freeze,
        {"refusal"=>"NotFound", "site"=>"entity_parent_no_identity", "template"=>"{command} acts on a {aggregate}'s {entity} — pass {identity}:"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"entity_unknown", "template"=>"{aggregate} has no entity {entity}"}.freeze,
        {"refusal"=>"NotFound", "site"=>"entity_element_no_identity", "template"=>"{command} acts on one {entity} — pass {identity}:"}.freeze,
        {"refusal"=>"NotFound", "site"=>"entity_element_missing", "template"=>"no {entity} with {identity} {wants} on {aggregate} {parent_id}"}.freeze,
        {"refusal"=>"NotFound", "site"=>"reference_target_missing", "template"=>"no {target} with {heads} {key}"}.freeze,
        {"refusal"=>"NotFound", "site"=>"read_model_reference_missing", "template"=>"no {aggregate} with reference {offered}"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"read_model_object_reference", "template"=>"{query} refused — a reference is an id, and {field} arrived as an object"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"no_query", "template"=>"{aggregate} has no query {query}"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"entity_query_missing", "template"=>"{entity} has no query {query}"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"entity_holds_no_list", "template"=>"{aggregate} holds no list of {entity}"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"entity_no_command", "template"=>"{entity} has no command {command}"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"aggregate_no_command", "template"=>"{aggregate} has no command {command}"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"port_no_operation", "template"=>"{port} has no operation {operation}"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"no_domain", "template"=>"no domain {domain} loaded (verb {verb})"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"no_read_model", "template"=>"{domain} has no read model {query}"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"not_fully_qualified", "template"=>"{verb} is not a fully-qualified verb (Domain::Aggregate.Command)"}.freeze,
        {"refusal"=>"UnknownVerb", "site"=>"no_aggregate", "template"=>"{domain} has no aggregate {aggregate}"}.freeze,
        {"refusal"=>"LifecycleRefused", "site"=>"transition_blocked", "template"=>"{command} refused — {field} is {current}, and {command} moves it only from {allowed}"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"value_object_shape", "template"=>"{name} is a {type} — pass its fields as an object, not {offered}"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"reference_as_object", "template"=>"{command} refused — a reference is an id, and {attribute} arrived as an object{known_by}"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"multi_field_scalar", "template"=>"{type} has multiple fields and cannot stand in for a scalar"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"composite_identity", "template"=>"{type} is a composite identity — an identity must have exactly one field"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"numeric_field", "template"=>"{type}.{field} expects {expected}, got {offered}"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"pattern_mismatch", "template"=>"{type}.{field} must match {pattern}, got {offered}"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"arithmetic_amount", "template"=>"{op} of {target} needs an Integer, got {offered}"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"arithmetic_current", "template"=>"{op} of {target} needs an Integer {target}, got {offered}"}.freeze,
        {"refusal"=>"TypeMismatch", "site"=>"arithmetic_shared_field", "template"=>"{op} of {target} needs a value object with one shared Integer field"}.freeze,
        {"refusal"=>"UnknownArgument", "site"=>"unknown_args", "template"=>"{command} does not declare {unknown} — it takes {declared}"}.freeze,
        {"refusal"=>"AbsentArgument", "site"=>"absent_args", "template"=>"{command} was not given {absent} — it takes {declared}"}.freeze,
        {"refusal"=>"InvariantViolation", "site"=>"closed_set_member", "template"=>"{type} admits {admitted} — got {offered}"}.freeze,
        {"refusal"=>"InvariantViolation", "site"=>"value_object_invariant", "template"=>"{name} invariant violated — {description} (given {offered})"}.freeze,
        {"refusal"=>"InvariantViolation", "site"=>"admits_declared_set", "template"=>"{name} admits {admits} — {admitted} — got {offered}"}.freeze,
        {"refusal"=>"InvariantViolation", "site"=>"undeclared_set", "template"=>"{name} admits {admits}, which this chapter does not declare — a closed set is named Aggregate::SetName, and it must be one the bluebook actually holds"}.freeze,
        {"refusal"=>"Unauthorized", "site"=>"tenant_required", "template"=>"{query} declares authorize with tenant: {field} — pass {field}: to name which {field} this ask is scoped to"}.freeze,
        {"refusal"=>"Unauthorized", "site"=>"role_mismatch", "template"=>"{command} refused — role: {role}, and the caller stated {caller_role}"}.freeze,
        {"refusal"=>"AttributeAbsent", "site"=>"absent_read", "template"=>"{aggregate} {field} is absent on this record — declared, not optional, and added since it was written. Backfill it in a translation (backfill :{field}, default: ...), or declare it optional: true"}.freeze,
        {"refusal"=>"ProjectionAbsent", "site"=>"absent_read", "template"=>"{aggregate} {field} is not yet projected on this record — declared via projects :{field}, but no rebuild sweep has populated it. Run the sweep, or read {reference}.{remote_field} directly if this rule cannot wait"}.freeze
      ].freeze,
      "SignTest" => [
        {"name"=>"positive?", "compares_via"=>">"}.freeze,
        {"name"=>"negative?", "compares_via"=>"<"}.freeze,
        {"name"=>"zero?", "compares_via"=>"=="}.freeze
      ].freeze,
      "SizedType" => [
        {"type"=>"Array"}.freeze,
        {"type"=>"String"}.freeze,
        {"type"=>"Hash"}.freeze
      ].freeze,
      "ToStringType" => [
        {"type"=>"String"}.freeze,
        {"type"=>"Integer"}.freeze,
        {"type"=>"Float"}.freeze,
        {"type"=>"TrueClass"}.freeze,
        {"type"=>"FalseClass"}.freeze,
        {"type"=>"NilClass"}.freeze
      ].freeze,
      "Trigger" => [
        {"name"=>"refused"}.freeze
      ].freeze,
      "VocabularyName" => [

      ].freeze
    }.freeze

    # THE TERMS — the first field of each row, which for a
    # one-field vocabulary is the whole of it. Derived ONCE and
    # frozen rather than mapped per call: these are constant
    # tables, and a constant that allocates a new array every
    # time it is read is not one.
    TERMS = TABLES.transform_values { |rows| rows.map { |row| row.values.first }.freeze }.freeze

    module_function

    # Refuses an unknown name rather than answering nil: a set
    # the language does not declare is a typo, not an empty set.
    def fetch(name) = TERMS.fetch(name)

    # The rows whole, for the vocabularies that carry more than
    # a term — Comparison's own algebra, RefusalTemplate's text.
    def rows(name) = TABLES.fetch(name)

    def symbols(name) = fetch(name).map(&:to_sym)

    def names = TABLES.keys
  end
end
