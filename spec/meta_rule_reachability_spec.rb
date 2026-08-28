require "spec_helper"
require "hecks/query_ir"

# Every declared given/invariant/ensures RULE must be SEEN REFUSING — not
# just the verb it hangs off.
#
# spec/judge_coverage_spec.rb proves every declared VERB is offered to the
# judge. That is necessary but not sufficient: offering a verb only opens
# the door a rule sits behind, and its own header names three prior escapes
# where a declaration nobody exercised sat underneath a green guard —
# unreachable rules, unjudged categories, a coverage guard that checked
# `*.Declare` and missed `Command.Argument`/`ValueObject.Field` entirely.
# Each time, the fix moved the grain finer. This is one grain finer again:
# a verb can be dispatched into constantly while the SPECIFIC rule attached
# to it never once sees the input that would make it refuse.
#
# spec/meta_rules_spec.rb is this codebase's own answer to that, and its own
# header states the standard plainly: "Every rule here must be SEEN
# REFUSING." What that file does not do is prove its own coverage is
# COMPLETE — it proves the rules someone remembered to write a refusing
# example for. This gate reads every given/invariant/ensures the meta-domain
# actually declares straight off the grammar (`Hecks::QueryIR.collect_rules`
# — the same enumeration `spec/fuzzing/meta_domain_coverage_spec.rb` already
# uses one level over, for attribute rather than rule coverage) and requires
# each one to be either PROVEN firing somewhere in the suite, cited by
# file:line, or named as an honest KNOWN_GAP — the same
# claim-or-name-the-gap discipline that file already established.
#
# THIS IS NOT A CLEAN GATE TODAY. As of this writing: 62 declared rules, 14
# proven, 48 open gaps. That number is not a target to defend down to zero
# in one sitting — it is the actual current size of the claim "a bluebook
# that violates an invariant refuses to boot," made visible and trackable
# instead of assumed. Closing a gap means either writing the refusing
# example (preferred — add it to spec/meta_rules_spec.rb and move the entry
# from META_RULE_KNOWN_GAPS to META_RULE_PROVEN below) or discovering the
# declaration is unreachable/dead (a fifth instance of this project's own
# characteristic defect, and worth its own fix).
RSpec.describe "reachability of the meta-domain's own given/invariant/ensures rules" do
  # EVERY RULE THE LANGUAGE DECLARES, read straight off the grammar — never
  # hand-copied, so a new given/invariant lands here the next run with no
  # second list to update. Keyed on [kind, location, description] exactly as
  # QueryIR.collect_rules reports it, the same identity the fuzz coverage
  # gate uses for "Construct#attribute" strings, one level over.
  ALL_META_RULES = Hecks::QueryIR.collect_rules(
    Hecks::Bluebook::MetaValidator.grammar_registry, "Bluebook"
  ).map { |r| [r.kind, r.location, r.description] }.freeze

  # PROVEN — cited by file:line, held to the same "seen failing" standard
  # spec/fuzzing/properties_spec.rb already holds every fuzzer property to.
  # A citation names the example that dispatches bad input at THIS declared
  # site and watches THIS rule (not a different one with similar wording —
  # `spec/meta_rules_spec.rb:126-132`'s "op admits Vocabulary::MutationOp"
  # invariant is real and proven but is not any of these 62; it is a
  # closed-set coercion, declared as `admits:`, not a given/invariant).
  META_RULE_PROVEN = {
    ["given", "Aggregate.Identify", "an identity part names something"]                      =>
                                                                                                "spec/meta_rules_spec.rb:243-249 (Aggregate.Identify with path: \"\")",
    ["invariant", "Aggregate::Description (declared)", "a description says something"]       =>
                                                                                                "spec/meta_rules_spec.rb:54-60 (Aggregate.Declare with description: \"\")",
    ["invariant", "Aggregate::FieldName (declared)", "an attribute is named"]                =>
                                                                                                "spec/meta_rules_spec.rb:62-65 (Aggregate.Attribute with name: \"\")",
    ["invariant", "Bluebook::Vision (declared)", "a vision says something"]                  =>
                                                                                                "spec/meta_rules_spec.rb:49-52 (Bluebook.Declare with vision: \"\")",
    ["given", "Command.Rule", "a rule says what it means"]                                   =>
                                                                                                "spec/meta_rules_spec.rb:97-100 (Command.Rule with description: \"\")",
    ["given", "Command.Rule", "a rule survives extraction"]                                  =>
                                                                                                "spec/meta_rules_spec.rb:102-105 (Command.Rule with canonical: \"\")",
    ["given", "Command.Change", "a mutation names a target"]                                 =>
                                                                                                "spec/meta_rules_spec.rb:107-113 (Command.Change with target: \"\")",
    ["given", "Command.ActsOn", "a command names what it acts on"]                           =>
                                                                                                "spec/meta_rules_spec.rb:148-151 (Command.ActsOn with root: \"\")",
    ["given", "Command.ActsOn", "a command acts on ONE root"]                                =>
                                                                                                "spec/meta_rules_spec.rb:141-146 (Command.ActsOn dispatched twice with different roots)",
    ["given", "Command.Announce", "an event is named"]                                       =>
                                                                                                "spec/meta_rules_spec.rb:134-137 (Command.Announce with announces: \"\")",
    ["given", "Entity.Identify", "an identity part names something"]                         =>
                                                                                                "spec/meta_rules_spec.rb:216-222 (Entity.Identify with path: \"\")",
    ["given", "Entity.Seal", "an entity says what it is known by"]                           =>
                                                                                                "spec/meta_rules_spec.rb:180-186 (Entity.Seal with no identity parts appended)",
    ["invariant", "ReadModel::ProjectionPurpose (declared)", "a description says something"] =>
                                                                                                "spec/dsl_spec.rb:866 (a read_model with description: \"\", via the ordinary DSL build path — MetaValidator.call surfaces it as DSL::Malformed rather than a direct dispatch, same rule)",
    ["given", "ValueObject.Member.Pair", "an admitted row binds a named field"]              =>
                                                                                                "spec/meta_rules_spec.rb:273-282 (ValueObject.Member.Pair with key: \"\")"
  }.freeze

  # HONEST, ITEMIZED GAPS — a declared rule this session did not prove
  # firing, with a real reason rather than a placeholder. Several are the
  # SAME generic presence-on-a-Rule pair ("a rule says what it means" / "a
  # rule survives extraction") declared redundantly at multiple owners —
  # META_RULE_PROVEN already proves that CONTENT fires at Command.Rule;
  # what is open here is that THIS site ever dispatches a bad rule to it.
  META_RULE_KNOWN_GAPS = {
    ["given", "Aggregate.Seal", "an aggregate says what it is known by"]                              =>
                                                                                                         "meta_rules_spec.rb only proves the positive path (\"seals an aggregate that is fully declared\", L293-297) — no example withholds every identity part and dispatches Aggregate.Seal to watch this given refuse",
    ["given", "Aggregate.Invariant", "a rule says what it means"]                                     =>
                                                                                                         "same generic Rule-presence check META_RULE_PROVEN already proves at Command.Rule — never dispatched at Aggregate.Invariant itself",
    ["given", "Aggregate.Invariant", "a rule survives extraction"]                                    =>
                                                                                                         "same generic Rule-presence check META_RULE_PROVEN already proves at Command.Rule — never dispatched at Aggregate.Invariant itself",
    ["given", "Aggregate.Precondition", "a rule says what it means"]                                  =>
                                                                                                         "same generic Rule-presence check, never dispatched at Aggregate.Precondition (the chapter-wide `given` an aggregate's own commands can reference)",
    ["given", "Aggregate.Precondition", "a rule survives extraction"]                                 =>
                                                                                                         "same generic Rule-presence check, never dispatched at Aggregate.Precondition",
    ["given", "Aggregate.Projects", "a projected field is named"]                                     =>
                                                                                                         "cross-aggregate projection (`projects`) is real DSL surface but no spec dispatches Aggregate.Projects with a blank field name",
    ["given", "Aggregate.Projects", "a projected field reads through a reference"]                    =>
                                                                                                         "no spec dispatches Aggregate.Projects naming a field that is not a declared reference",
    ["given", "Aggregate.Projects", "a projected field names a remote field"]                         =>
                                                                                                         "no spec dispatches Aggregate.Projects with a blank remote field name",
    ["invariant", "Aggregate::AggregateName (declared)", "an aggregate is named"]                     =>
                                                                                                         "presence invariant on the aggregate's own name; every real bluebook and the golden IR fixture always supplies one, so nothing ever dispatches Aggregate.Declare with name: \"\"",
    ["invariant", "Aggregate::TypeName (declared)", "a type is named"]                                =>
                                                                                                         "presence invariant on an attribute's type reference; no spec dispatches Aggregate.Attribute with a blank type",
    ["invariant", "Aggregate::ListFlag (declared)", "list is true or false"]                          =>
                                                                                                         "closed-set invariant on an attribute's list flag; no spec dispatches a value outside {\"true\",\"false\"}",
    ["ensures", "Bluebook.Attach", "the list grew by exactly one"]                                    =>
                                                                                                         "postcondition on attaching a sub-chapter (Paging is the one real user); no spec creates the double-count/no-op condition that would make this ensures fail",
    ["invariant", "Bluebook::BluebookName (declared)", "a chapter is named"]                          =>
                                                                                                         "presence invariant on a bluebook's own name; nothing dispatches Bluebook.Declare with name: \"\"",
    ["invariant", "Bluebook::Classification (declared)", "a chapter is core, supporting, or generic"] =>
                                                                                                         "closed-set invariant; no spec dispatches a classification outside the three-member set",
    ["invariant", "Bluebook::Version (declared)", "a version says something"]                         =>
                                                                                                         "presence invariant on a bluebook's version; no spec dispatches one blank",
    ["invariant", "Bluebook::FormerlyKnownAs (declared)", "a formerly_known_as says something"]       =>
                                                                                                         "presence invariant; no spec dispatches a blank formerly_known_as entry",
    ["invariant", "Bluebook::AttachesToContext (declared)", "an attachment names a context"]          =>
                                                                                                         "presence invariant on ADR 0026's attaches_to context; no spec dispatches one blank",
    ["given", "Command.Ensure", "a rule says what it means"]                                          =>
                                                                                                         "same generic Rule-presence check META_RULE_PROVEN proves at Command.Rule, here for the `ensures` block instead of `given` — never dispatched with a blank description",
    ["given", "Command.Ensure", "a rule survives extraction"]                                         =>
                                                                                                         "same generic Rule-presence check, never dispatched at Command.Ensure with a blank canonical",
    ["given", "Command.Change", "a mutation does something"]                                          =>
                                                                                                         "distinct from \"a mutation names a target\" (proven) — no spec dispatches Command.Change with a target but no actual operation",
    ["invariant", "Command::CommandName (declared)", "a command is named"]                            =>
                                                                                                         "presence invariant on a command's own name; nothing dispatches Command.Declare with name: \"\"",
    ["invariant", "Command::ArgName (declared)", "an argument is named"]                              =>
                                                                                                         "presence invariant on a command argument's name; no spec dispatches one blank",
    ["given", "Entity.Precondition", "a rule says what it means"]                                     =>
                                                                                                         "same generic Rule-presence check, never dispatched at Entity.Precondition",
    ["given", "Entity.Precondition", "a rule survives extraction"]                                    =>
                                                                                                         "same generic Rule-presence check, never dispatched at Entity.Precondition",
    ["given", "Entity.Invariant", "a rule says what it means"]                                        =>
                                                                                                         "same generic Rule-presence check, never dispatched at Entity.Invariant",
    ["given", "Entity.Invariant", "a rule survives extraction"]                                       =>
                                                                                                         "same generic Rule-presence check, never dispatched at Entity.Invariant",
    ["invariant", "Entity::EntityName (declared)", "an entity is named"]                              =>
                                                                                                         "presence invariant on a piece's own name; nothing dispatches Entity.Declare with name: \"\"",
    ["invariant", "Policy::PolicyName (declared)", "a policy is named"]                               =>
                                                                                                         "presence invariant on a policy's own name; no spec dispatches one blank",
    ["invariant", "ProcessManager::ProcessManagerName (declared)", "a process manager is named"]      =>
                                                                                                         "presence invariant on a saga's own name; no spec dispatches one blank",
    ["given", "ReadModel.GroupBy", "a group_by field is named"]                                       =>
                                                                                                         "no spec dispatches ReadModel.GroupBy with a blank field name",
    ["given", "ReadModel.Median", "a median field is named"]                                          =>
                                                                                                         "no spec dispatches ReadModel.Median with a blank field name",
    ["given", "ReadModel.Option", "an option is named"]                                               =>
                                                                                                         "no spec dispatches ReadModel.Option with a blank option name",
    ["invariant", "ReadModel::ReadModelName (declared)", "a read model is named"]                     =>
                                                                                                         "presence invariant on a read model's own name; nothing dispatches ReadModel.Declare with name: \"\"",
    ["invariant", "ReadModel::GroupByField (declared)", "a group_by field is named"]                  =>
                                                                                                         "same content as ReadModel.GroupBy's given, declared a second time as an invariant on the field row itself; neither site is dispatched with a blank name",
    ["given", "Query.Option", "an option is named"]                                                   =>
                                                                                                         "same content as ReadModel.Option's given, one construct over; no spec dispatches Query.Option with a blank name",
    ["invariant", "Query::QueryName (declared)", "a query is named"]                                  =>
                                                                                                         "presence invariant on a query's own name; nothing dispatches Query.Declare with name: \"\"",
    ["given", "ValueObject.Close", "a closed set admits a member"]                                    =>
                                                                                                         "`closed_set`'s own admit-a-member given; no spec withholds the member value to watch it refuse",
    ["given", "ValueObject.Assert", "a rule says what it means"]                                      =>
                                                                                                         "same generic Rule-presence check, never dispatched at ValueObject.Assert (a shape's own `assert`)",
    ["given", "ValueObject.Assert", "a rule survives extraction"]                                     =>
                                                                                                         "same generic Rule-presence check, never dispatched at ValueObject.Assert",
    ["invariant", "ValueObject::ValueObjectName (declared)", "a value object is named"]               =>
                                                                                                         "meta_rules_spec.rb's own comment (L77-86) notes this invariant is masked by ValueObjectName's TypeMismatch for a plain empty string — reaching it needs a whitespace-only name, which no spec supplies",
    ["invariant", "ValueObject::ShapeField (declared)", "a field is named"]                           =>
                                                                                                         "presence invariant on a value object's own field name; no spec dispatches one blank",
    ["invariant", "ValueObject::ShapeField (declared)", "a field has a type"]                         =>
                                                                                                         "presence invariant on a value object field's type; no spec dispatches one blank",
    ["invariant", "ValueObject::ShapeField (declared)", "a field's list mode is specified"]           =>
                                                                                                         "presence invariant on a value object field's list flag; no spec dispatches one blank",
    ["invariant", "ValueObject::Assertion (declared)", "an assertion description is present"]         =>
                                                                                                         "presence invariant on a shape's own `assert` row; no spec dispatches one blank",
    ["invariant", "ValueObject::Assertion (declared)", "an assertion canonical form is present"]      =>
                                                                                                         "presence invariant on the same row's canonical text; no spec dispatches one blank",
    ["invariant", "ValueObject::Pair (declared)", "a pair key is present"]                            =>
                                                                                                         "presence invariant on an admitted Member row's key; no spec dispatches one blank (contrast: ValueObject.Member.Pair's own GIVEN of the same shape IS proven, above — the invariant declared on the row itself is not)",
    ["invariant", "Syntax::SyntaxName (declared)", "a syntax is named"]                               =>
                                                                                                         "META-DOMAIN-ONLY grammar table (ADR 0026, S14) — Syntax data is seeded once by SyntaxBoot, never dispatched through the ordinary DSL by any real domain, so nothing ever reaches this invariant with a blank name",
    ["invariant", "Vocabulary::VocabularyName (declared)", "a vocabulary is named"]                   =>
                                                                                                         "META-DOMAIN-ONLY grammar table, same reasoning as Syntax::SyntaxName — Vocabulary is static declaration read by spec/vocabulary_conformance_spec.rb, never dispatched with a blank name"
  }.freeze

  it "proves, or names a gap for, every given/invariant/ensures the language declares" do
    accounted = META_RULE_PROVEN.keys.to_set | META_RULE_KNOWN_GAPS.keys.to_set
    unaccounted = ALL_META_RULES - accounted.to_a

    expect(unaccounted).to be_empty,
                           "the meta-domain declares #{unaccounted.size} rule(s) with no proof of firing and no " \
                           "named META_RULE_KNOWN_GAPS entry — a given/invariant/ensures just joined the language " \
                           "with nothing deciding, on purpose, whether it can ever be seen refusing:\n  " +
                           unaccounted.map(&:inspect).join("\n  ")
  end

  it "never lets a proof rot — every META_RULE_PROVEN entry names a rule the language still declares" do
    stale = META_RULE_PROVEN.keys - ALL_META_RULES

    expect(stale).to be_empty,
                     "META_RULE_PROVEN cites #{stale.size} rule(s) the language no longer declares at that site — " \
                     "a rename, removal, or relocation left a citation pointing at nothing:\n  " +
                     stale.map(&:inspect).join("\n  ")
  end

  it "never lets a named gap rot either — the same drift check, aimed at META_RULE_KNOWN_GAPS" do
    stale = META_RULE_KNOWN_GAPS.keys - ALL_META_RULES

    expect(stale).to be_empty,
                     "META_RULE_KNOWN_GAPS names #{stale.size} rule(s) the language no longer declares at that " \
                     "site — a rename or removal left an open gap pointing at nothing:\n  " +
                     stale.map(&:inspect).join("\n  ")
  end

  it "keeps a proven rule from also sitting in KNOWN_GAPS" do
    overlap = META_RULE_PROVEN.keys.to_set & META_RULE_KNOWN_GAPS.keys.to_set

    expect(overlap).to be_empty,
                       "#{overlap.to_a.inspect} is both cited as PROVEN and listed as an open gap — pick one"
  end
end
