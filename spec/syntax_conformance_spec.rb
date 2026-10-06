require "spec_helper"

# Holds language/bluebook/syntax.bluebook's declared words to the surface the
# builders actually answer, in both directions, so neither can drift unnoticed.
RSpec.describe "the declared syntax" do
  D = Hecks::Bluebook::DSL

  def self.judged_meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.syntax = judged_meta.aggregates.find { |a| a.hecks_name == "Syntax" }

  # The same chapter, reachable from inside an example.
  def meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  # Every cell as text. Fields decode back through typed literal decoding on
  # the way out of reconstruction, the same path Attribute#list takes.
  def self.rows(name)
    syntax.value_objects.find { |vo| vo.hecks_name == name }
          .members.map { |row| row.to_h.transform_values(&:to_s) }
  end

  # Keyword/Argument are dispatched through the real admission/lifecycle door
  # (`SyntaxBoot.call`), not read as a static closed set the way Context/Body/
  # ArgumentKind still are — so their own `status` really is a lifecycle.
  KEYWORDS      = Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
  ARGUMENTS     = Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:arguments]
  CONTEXTS      = rows("Context").map { |row| row[:name] }
  BODIES        = rows("Body").map { |row| row[:name] }
  ARGUMENT_KIND = rows("ArgumentKind").map { |row| row[:name] }

  # Admitted/deprecated words are live and run every builder⇄row gate below.
  # Proposed (no builder yet) and retired (no builder now) get their own
  # gates instead. An absent status reads as admitted (see syntax_lifecycle_spec).
  def self.status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s

  def self.live?(row) = %w[admitted deprecated].include?(status_of(row))

  LIVE_KEYWORDS  = KEYWORDS.select { |row| live?(row) }
  LIVE_KEYS      = LIVE_KEYWORDS.map { |row| [row[:word], row[:context]] }.uniq
  LIVE_ARGUMENTS = ARGUMENTS.select { |row| live?(row) && LIVE_KEYS.include?([row[:keyword], row[:context]]) }

  # Where each context's words are answered. `File` has no builder class —
  # `Hecks.bluebook` reaches through a module — and `Type` inherits whichever
  # `list_of`/`one_of` the enclosing builder has. `OneOf` shares
  # ValueObjectBuilder with `ValueObject`, so the completeness check below
  # groups contexts by `BUILDER` rather than comparing each context alone.
  BUILDER = {
    "File"                 => Hecks,
    "Bluebook"             => D::BluebookBuilder,
    "Aggregate"            => D::AggregateBuilder,
    "Entity"               => D::EntityBuilder,
    "Command"              => D::CommandBuilder,
    "Query"                => D::QueryBuilder,
    "ValueObject"          => D::ValueObjectBuilder,
    "OneOf"                => D::ValueObjectBuilder,
    "Lifecycle"            => D::LifecycleBuilder,
    "Policy"               => D::PolicyBuilder,
    "ProcessManager"       => D::ProcessManagerBuilder,
    "Handler"              => D::ProcessManagerBuilder::HandlerBuilder,
    "Dispatch"             => D::ProcessManagerBuilder::HandlerBuilder::DispatchBuilder,
    "ReadModel"            => D::ReadModelBuilder,
    "Type"                 => D::AttributeCollector,
    "Hecksagon"            => D::HecksagonBuilder,
    "World"                => D::WorldBuilder,
    "DomainPort"           => D::DomainPortBuilder,
    "PortOperation"        => D::PortOperationBuilder,
    "Port"                 => D::PortBuilder,
    "Adapter"              => D::AdapterBuilder,
    "Translation"          => D::TranslationBuilder,
    "TranslationAggregate" => D::TranslationAggregateBuilder
  }.freeze

  # Public methods a bluebook word could never mean: builder bookkeeping, the
  # runtime facade, or a sibling artifact's own open verb vocabulary. Kept here,
  # with reasons, so an unexplained allowlist can't quietly cover a retired word.
  NOT_A_WORD = {
    "Bluebook"  => {
      classification:                         "an attr_reader BluebookBuilder.build reads when merging one chapter across files",
      resolve_pending_chapter_givens!:        "called by MetaValidator.judge_deferred! once a chapter split " \
                                              "across files has fully loaded, to resolve any bare chapter-given " \
                                              "reference an earlier file left pending",
      resolve_pending_chapter_entity_givens!: "the entity-scoped analogue, one level down — called by " \
                                              "MetaValidator.judge_deferred! the same way, to resolve any " \
                                              "bare entity-level given reference an earlier file left pending"
    },
    "File"      => {
      boot:             "the runtime facade, not a declaration",
      boot_files:       "the runtime facade, not a declaration — the explicit-file sibling of boot",
      describe:         "the runtime facade, not a declaration — boot's declarations-only sibling",
      boot_described:   "the runtime facade, not a declaration — finishes a boot from what describe loaded",
      with_registry:    "the runtime facade, not a declaration",
      current_registry: "the runtime facade, not a declaration",
      as_caller:        "the runtime facade, not a declaration",
      # `behaviors` (lib/hecks/behaviors.rb) is opt-in and never collected
      # into a domain Registry, so it carries no syntax row of its own.
      behaviors:        "the behaviors-suite entry point, not a bluebook declaration"
    },
    "Hecksagon" => {
      binds:          "the builder's own collected Bind records, read by whoever owns them",
      subscriptions:  "the builder's own collected subscription strings, read by whoever owns them",
      attachments:    "the builder's own collected attachments (name and source), read by whoever owns them",
      # The open verb catch-all: `persisted_by "Heki"` bare reaches
      # HecksagonBuilder#method_missing — the verb is whichever bind-shaped
      # word a domain declares, not a closed set this table could enumerate.
      method_missing: "the open domain-level-default-bind catch-all — same boundary as World's own"
    },
    "World"     => {
      # The open verb-settings catch-all: `posted_by("Carrier") { office "EC1" }`
      # reaches WorldBuilder#method_missing — the verb is whichever port a
      # domain declares, not a closed set this table could enumerate.
      method_missing:        "the open port-verb settings catch-all — .world's adapter-binding " \
                             "vocabulary is per-application, not a fixed set the language can enumerate",
      # Same shape as `realm_impl` in the "*" table: what the word's `calls:`
      # row forwards to, not a second word.
      default_database_impl: "WorldBuilder's own real implementation, called by GenericDispatch's calls:",
      default_adapter_impl:  "WorldBuilder's own real implementation, called by GenericDispatch's calls:",
      # Not a word itself, same reasoning as `attribute_impl` in the "*" table
      # below — the thing a word's own dispatch calls, not a second word.
      record_binding:        "the shared @settings write path both the bare and aggregate-qualified " \
                             "bind spellings call into — not a word of its own"
    },
    "*"         => {
      build:              "the builder's closing act, called by self.build",
      attributes:         "AttributeCollector's collection, read by whoever owns it",
      closed_sets:        "AttributeCollector's synthesised sets, installed by the aggregate",
      dispatches:         "HandlerBuilder's collection, read by ProcessManagerBuilder",
      add_aggregate_head: "ReadModelBuilder's own build calls it; nothing types it",
      # `_impl`-suffixed methods below aren't words themselves: each Keyword
      # row's `calls:` column names one as the real method its word forwards
      # to, so the row keeps the plain spelling (e.g. "attribute", not "attribute_impl").
      attribute_impl:     "AttributeCollector's own real implementation, called by GenericDispatch's calls:",
      role_impl:          "CommandBuilder's own real implementation, called by GenericDispatch's calls:",
      unresolved_impl:    "TranslationAggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      has_many_impl:      "AggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      has_one_impl:       "AggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      belongs_to_impl:    "AggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      trigger_impl:       "PolicyBuilder's own real implementation, called by GenericDispatch's calls:",
      on_impl:            "PolicyBuilder's own real implementation, called by GenericDispatch's calls:",
      dispatch_impl:      "HandlerBuilder's own real implementation, called by GenericDispatch's calls:",
      compensates_impl:   "DispatchBuilder's own real implementation, called by GenericDispatch's calls:",
      given_impl:         "the owning builder's own real implementation, called by GenericDispatch's calls:",
      invariant_impl:     "the owning builder's own real implementation, called by GenericDispatch's calls:",
      reference_to_impl:  "the owning builder's own real implementation, called by GenericDispatch's calls:",
      aggregate_impl:     "the owning builder's own real implementation, called by GenericDispatch's calls:",
      attaches_to_impl:   "BluebookBuilder's own real implementation, called by GenericDispatch's calls:",
      provides_impl:      "BluebookBuilder's own real implementation, called by GenericDispatch's calls:",
      across_impl:        "PolicyBuilder's own real implementation, called by GenericDispatch's calls:",
      provenance_impl:    "the owning builder's own real implementation, called by GenericDispatch's calls:",
      needs_impl:         "CommandBuilder's own real implementation, called by GenericDispatch's calls:",
      identified_by_impl: "IdentityDeclaration's own real implementation, called by GenericDispatch's calls:",
      lifecycle_impl:     "the owning builder's own real implementation, called by GenericDispatch's calls:",
      entity_impl:        "the owning builder's own real implementation, called by GenericDispatch's calls:",
      query_impl:         "the owning builder's own real implementation, called by GenericDispatch's calls:",
      policy_impl:        "AggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      command_impl:       "the owning builder's own real implementation, called by GenericDispatch's calls:",
      projects_impl:      "AggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      sets_impl:          "CommandBuilder's own real implementation, called by GenericDispatch's calls:",
      delegates_to_impl:  "CommandBuilder's own real implementation, called by GenericDispatch's calls:",
      corrects_impl:      "CommandBuilder's own real implementation, called by GenericDispatch's calls:",
      member_impl:        "ValueObjectBuilder's own real implementation, called by GenericDispatch's calls:",
      where_impl:         "QuerySpecification::Common::DSL's own real implementation, called by GenericDispatch's calls:",
      order_by_impl:      "QuerySpecification::Common::DSL's own real implementation, called by GenericDispatch's calls:",
      authorize_impl:     "QuerySpecification::Common::DSL's own real implementation, called by GenericDispatch's calls:",
      limit_impl:         "QuerySpecification::Common::DSL's own real implementation, called by GenericDispatch's calls:",
      offset_impl:        "QuerySpecification::Common::DSL's own real implementation, called by GenericDispatch's calls:",
      include_impl:       "ReadModelBuilder's own real implementation, called by GenericDispatch's calls:",
      group_by_impl:      "ReadModelBuilder's own real implementation, called by GenericDispatch's calls:",
      percentile_impl:    "ReadModelBuilder's own real implementation, called by GenericDispatch's calls:",
      transition_impl:    "the owning builder's own real implementation, called by GenericDispatch's calls:",
      starts_on_impl:     "ProcessManagerBuilder's own real implementation, called by GenericDispatch's calls:",
      ends_on_impl:       "ProcessManagerBuilder's own real implementation, called by GenericDispatch's calls:",
      tells_impl:         "DomainPortBuilder's own real implementation, called by GenericDispatch's calls: " \
                          "— also the target for the \"operation\" spelling, a Ruby alias no more",
      asks_impl:          "DomainPortBuilder's own real implementation, called by GenericDispatch's calls:",
      answers_query_impl: "DomainPortBuilder's own real implementation, called by GenericDispatch's calls:",
      rename_impl:        "TranslationAggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      move_impl:          "TranslationAggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      convert_impl:       "TranslationAggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      retype_impl:        "TranslationAggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      compute_impl:       "TranslationAggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      rekey_impl:         "TranslationAggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      backfill_impl:      "TranslationAggregateBuilder's own real implementation, called by GenericDispatch's calls:",
      port_impl:          "HecksagonBuilder's own real implementation, called by GenericDispatch's calls:",
      realm_impl:         "WorldBuilder's own real implementation, called by GenericDispatch's calls:",
      latest_impl:        "WorldBuilder's own real implementation, called by GenericDispatch's calls:",
      then_set_impl:      "CommandBuilder's own real implementation, called by GenericDispatch's calls:",
      list_of_impl:       "AttributeCollector's own real implementation, called by GenericDispatch's calls:",
      one_of_impl:        "the owning builder's own real implementation, called by GenericDispatch's calls:"
    }
  }.freeze

  # The one place a spelling and a Ruby signature diverge: `transition` takes
  # one Hash and deletes `:from` out of it, so `from:` is written like a kwarg
  # but received as a reserved key of the pairs argument.
  RESERVED_KEY = { %w[transition Lifecycle] => %w[from], %w[transition ProcessManager] => %w[from] }.freeze

  def self.words_answered_by(context)
    listed = public_methods_of(BUILDER.fetch(context))
    listed - NOT_A_WORD.fetch("*").keys - NOT_A_WORD.fetch(context, {}).keys
  end

  def self.public_methods_of(builder)
    return builder.methods - Module.methods if builder.equal?(Hecks)
    return builder.public_instance_methods - Object.public_instance_methods if builder.is_a?(Class)

    builder.public_instance_methods(false)
  end

  def self.contexts_of(builder) = BUILDER.select { |_, candidate| candidate == builder }.keys

  def method_for(word, context)
    builder = BUILDER.fetch(context)
    return builder.method(word) if builder.equal?(Hecks)

    builder.instance_method(word)
  end

  # A GenericDispatch word has no real method to introspect — this reads its
  # shape straight off the `ARGUMENTS` rows; `Hecks` is excluded outright.
  def generically_dispatched?(word, context)
    builder = BUILDER.fetch(context)
    return false if builder.equal?(Hecks)

    !builder.method_defined?(word.to_sym) && D::GenericDispatch.handles?(context, word.to_s)
  end

  def declared_in(context) = LIVE_KEYWORDS.select { |row| row[:context] == context }

  it "spells every cell with a word the language admits", :aggregate_failures do
    expect(KEYWORDS.map { |row| row[:context] }.uniq - CONTEXTS).to be_empty
    expect(KEYWORDS.map { |row| row[:body] }.uniq - BODIES).to be_empty
    expect(ARGUMENTS.map { |row| row[:kind] }.uniq - ARGUMENT_KIND).to be_empty
    expect(ARGUMENTS.map { |row| row[:context] }.uniq - CONTEXTS).to be_empty
  end

  # `admits:` is a link the language can make and a closed set is not a root, so
  # nothing resolves it for a value object nobody instantiates. Checked here
  # instead, or the three `admits:` in syntax.bluebook would be decoration.
  # Keyword/Argument are entities of Syntax, reached through `.entities` the same way `syntax`
  # reaches every other real entity. Each triple is an entity, its column and the set it admits.
  ADMITS_LINKS = [%w[Keyword context Context], %w[Keyword body Body],
                  %w[Argument context Context], %w[Argument kind ArgumentKind]].freeze

  def admitting_attribute(entity_name, field)
    entity = self.class.syntax.entities.find { |e| e.hecks_name == entity_name }
    entity.attributes.find { |a| a.name.to_s == field }
  end

  it "holds every admits-bearing column to the set it names", :aggregate_failures do
    ADMITS_LINKS.each do |entity_name, field, set|
      expect(admitting_attribute(entity_name, field).admits).to eq("Syntax::#{set}"),
                                                                "#{entity_name}.#{field} should admit Syntax::#{set}"
    end
  end

  ENTERED_CONTEXTS = KEYWORDS.map { |row| row[:inner] }.reject(&:empty?).uniq
  SPOKEN_CONTEXTS  = KEYWORDS.map { |row| row[:context] }.uniq

  it "enters every context it declares, and declares words for every context it enters", :aggregate_failures do
    # `File` is the outside of every body, so nothing opens it; `Type` is the
    # second argument of `attribute`, entered by position, never by a `do`.
    expect((SPOKEN_CONTEXTS - ENTERED_CONTEXTS).sort).to eq(%w[File Type]), "a context is spoken in but nothing opens it"
    expect(ENTERED_CONTEXTS - SPOKEN_CONTEXTS).to be_empty, "a word opens a body no word may be typed in"
  end

  def answers?(builder, word, context)
    return Hecks.respond_to?(word) if builder.equal?(Hecks)

    builder.method_defined?(word) || generically_dispatched?(word, context)
  end

  def unanswered_words(context)
    builder = BUILDER.fetch(context)
    declared_in(context).map { |row| row[:word].to_sym }.uniq.reject { |word| answers?(builder, word, context) }
  end

  CONTEXTS.each do |context|
    describe context do
      it "declares only words the builder answers" do
        undeclared = unanswered_words(context)

        expect(undeclared).to be_empty,
                              "#{context} declares #{undeclared.inspect}, which #{BUILDER.fetch(context)} does not answer"
      end
    end
  end

  def declared_words(contexts)
    contexts.flat_map { |ctx| declared_in(ctx).flat_map { |row| [row[:word], row[:was].to_s].reject(&:empty?) } }
            .map(&:to_sym).uniq
  end

  # A Type-position word (`list_of`/`one_of`) counts as declared here
  # unless the builder's own context already has a row of that name —
  # the same "own context first, Type second" order WordGate's dispatch fallback checks.
  def type_position_words(contexts)
    own_words = contexts.flat_map { |ctx| declared_in(ctx).map { |row| row[:word] } }.uniq
    LIVE_KEYWORDS.select { |row| row[:context] == "Type" }
                 .map { |row| row[:word] }
                 .reject { |word| own_words.include?(word) }
                 .map(&:to_sym)
  end

  def undeclared_words(builder, contexts)
    declared = declared_words(contexts)
    declared += type_position_words(contexts) if builder.is_a?(Class) && builder.include?(D::AttributeCollector)
    answered = contexts.flat_map { |ctx| self.class.words_answered_by(ctx) }.uniq
    (answered - declared).sort
  end

  # Grouped by `BUILDER` since ValueObject/OneOf share one and AttributeCollector
  # mixes into five. A builder's own `one_of(&block)` shadows AttributeCollector's
  # `one_of(*values)`, so a mixed-in word counts as declared only while unshadowed.
  BUILDER.values.uniq.each do |builder|
    next if builder.equal?(D::AttributeCollector)

    it "declares every word #{builder} answers (#{contexts_of(builder).join(", ")})" do
      message = "#{builder} answers words the language does not declare — a bluebook could use them " \
                "and nothing projected from the language would know they exist"

      expect(undeclared_words(builder, self.class.contexts_of(builder))).to be_empty, message
    end
  end

  # The new spelling may answer through GenericDispatch's `calls:` rather
  # than a literal method (`generically_dispatched?` below); the previous
  # spelling must stay literal — `WordGate` matches `was:` by exact lookup.
  def new_spelling_answered?(row, answered)
    answered.include?(row[:word].to_sym) || generically_dispatched?(row[:word], row[:context])
  end

  def rename_problems(row)
    name = "#{row[:context]}.#{row[:word]}"
    answered = self.class.words_answered_by(row[:context])
    stranded = "#{name} was #{row[:was]}, and the old spelling stopped parsing — a rename never strands the old era"
    [("#{name} — the new spelling has no builder" unless new_spelling_answered?(row, answered)),
     (stranded unless answered.include?(row[:was].to_sym)),
     ("#{name} renames itself" if row[:was] == row[:word])].compact
  end

  # A live row carrying `was:` is a word the language respelled: the builder
  # must answer both spellings, the previous spelling isn't smuggled back in
  # as its own row, and nothing renames a word to itself.
  it "answers every renamed word in both its spellings" do
    renamed = LIVE_KEYWORDS.reject { |row| row[:was].to_s.empty? }

    expect(renamed.flat_map { |row| rename_problems(row) }).to be_empty
  end

  it "keeps no renamed-away spelling as a row of its own" do
    respelled = KEYWORDS.reject { |row| row[:was].to_s.empty? }
                        .map { |row| [row[:was], row[:context]] }
    ghosts = respelled & KEYWORDS.map { |row| [row[:word], row[:context]] }

    expect(ghosts).to be_empty,
                      "old spellings declared twice — as was: and as a row: #{ghosts.inspect}"
  end

  # A proposed word is declared but not yet implemented — a builder already
  # answering it means it earned admission. A retired word is the reverse:
  # a builder still answering it means it never actually left.
  it "leaves every proposed word unanswered — answered means admit it" do
    early = KEYWORDS.select { |row| self.class.status_of(row) == "proposed" }
                    .select { |row| self.class.words_answered_by(row[:context]).include?(row[:word].to_sym) }

    expect(early).to be_empty,
                     "#{early.map { |row| "#{row[:context]}.#{row[:word]}" }.join(", ")} " \
                     "— proposed, but the builder already answers; run hecks admit"
  end

  it "leaves every retired word unanswered — answered means it never left" do
    lingering = KEYWORDS.select { |row| self.class.status_of(row) == "retired" }
                        .select { |row| self.class.words_answered_by(row[:context]).include?(row[:word].to_sym) }

    expect(lingering).to be_empty,
                         "#{lingering.map { |row| "#{row[:context]}.#{row[:word]}" }.join(", ")} " \
                         "— retired, but the builder still answers"
  end

  it "joins every argument row to a word" do
    keys    = KEYWORDS.map { |row| [row[:word], row[:context]] }.uniq
    widowed = ARGUMENTS.map { |row| [row[:keyword], row[:context]] }.uniq - keys

    expect(widowed).to be_empty, "argument rows joining to no keyword: #{widowed.inspect}"
  end

  # Each live word whose builder has a real method to introspect, with the argument rows it
  # declares.
  def introspectable_arguments
    LIVE_ARGUMENTS.group_by { |row| [row[:keyword], row[:context]] }
                  .reject { |(word, context), _| generically_dispatched?(word, context) }
  end

  # The keyword names of a `Method#parameters` list, an Array of [kind, name] pairs.
  def keyword_names(params) = params.filter_map { |kind, name| name.to_s if %i[key keyreq].include?(kind) }

  def spelled_keywords(args) = args.reject { |row| row[:named].empty? }.map { |row| row[:named] }.uniq

  def keyword_gap_problems(name, undeclared, unspelled)
    [("#{name} declares #{undeclared.sort.inspect}, which its builder does not take" unless undeclared.empty?),
     ("#{name}'s builder takes #{unspelled.sort.inspect}, which the language does not declare" unless unspelled.empty?)].compact
  end

  def keyword_argument_problems(word, context, args)
    taken = keyword_names(method_for(word, context).parameters)
    spelled = spelled_keywords(args)
    undeclared = spelled - taken - RESERVED_KEY.fetch([word, context], [])
    keyword_gap_problems("#{context}.#{word}", undeclared, taken - spelled)
  end

  it "declares every keyword argument each word's builder takes, and no other" do
    problems = introspectable_arguments.flat_map { |(word, context), args| keyword_argument_problems(word, context, args) }

    expect(problems).to be_empty
  end

  # An inline hash at a call site binds to a positional Hash parameter or to
  # a **keyrest, and the spelling does not distinguish them — `where(a: 1)`
  # and `member a: 1` are typed identically and land differently.
  def positional_room(positional, params)
    room = params.count { |kind, _| %i[req opt].include?(kind) }
    room += 1 if positional.any? { |row| row[:kind] == "pairs" } && params.any? { |kind, _| kind == :keyrest }
    room
  end

  def too_many_positionals?(positional, params)
    return false if params.any? { |kind, _| kind == :rest } # `one_of("small", "large")` is variadic

    positional.map { |row| row[:at] }.map(&:to_i).max > positional_room(positional, params)
  end

  def positional_problem(word, context, args)
    positional = args.reject { |row| row[:at].empty? }
    return if positional.empty?
    return unless too_many_positionals?(positional, method_for(word, context).parameters)

    "#{context}.#{word} declares more positionals than its builder takes"
  end

  it "declares no more positionals than each word's builder takes" do
    problems = introspectable_arguments.filter_map { |(word, context), args| positional_problem(word, context, args) }

    expect(problems).to be_empty
  end

  # The arguments a builder demands, each paired with the row declaring it (nil when none does).
  def demanded_positionals(params, args)
    params.each_with_index.filter_map do |(kind, name), index|
      [name.to_s, args.find { |row| row[:at] == (index + 1).to_s }] if kind == :req
    end
  end

  def demanded_keywords(params, args)
    params.filter_map { |kind, name| ["#{name}:", args.find { |row| row[:named] == name.to_s }] if kind == :keyreq }
  end

  def demanded_arguments(params, args) = demanded_positionals(params, args) + demanded_keywords(params, args)

  def demanded_but_optional(word, context, args)
    demanded_arguments(method_for(word, context).parameters, args).filter_map do |label, row|
      "#{context}.#{word}'s #{label} is required by the builder and declared optional" if row && row[:required] != "true"
    end
  end

  # A builder demanding an argument the language calls optional is a bluebook
  # that parses everywhere and loads nowhere — checked one way on purpose:
  # optional may be declared required, but required may never be declared optional.
  it "never calls an argument optional that the builder demands" do
    problems = introspectable_arguments.flat_map { |(word, context), args| demanded_but_optional(word, context, args) }

    expect(problems).to be_empty
  end

  def sets_rows
    ARGUMENTS.select { |row| row[:keyword] == "sets" && row[:context] == "Command" && !row[:selects].empty? }
  end

  def live_kwarg_ops = D::CommandBuilder::KWARG_TO_OP.transform_keys(&:to_s).transform_values(&:to_s)

  def op_mismatch(row)
    declared_op = row[:selects].delete_prefix("op=")
    return if live_kwarg_ops[row[:named]] == declared_op

    "sets' #{row[:named]}: selects op=#{declared_op} in the language, " \
      "but CommandBuilder::KWARG_TO_OP maps it to #{live_kwarg_ops[row[:named]].inspect}"
  end

  # `selects` mirrors rust/parser/src/keywords.rs's `ArgumentRow.selects` field.
  # `to:` is the one kwarg whose name differs from the op it selects, so this
  # checks what "declares every keyword argument..." above cannot catch.
  it "selects the same op CommandBuilder::KWARG_TO_OP maps each named argument to", :aggregate_failures do
    expect(sets_rows).not_to be_empty
    expect(sets_rows.filter_map { |row| op_mismatch(row) }).to be_empty
    expect(sets_rows.map { |row| row[:named] }).to match_array(live_kwarg_ops.keys)
  end

  # A context's category is where its `fills` must land. `Lifecycle` folds onto
  # whichever of Aggregate/Entity opened it, so it's checked against both;
  # `Type` is a position, not a record, so nothing it declares may fill anything.
  CATEGORY_OF = {
    # `hecksagon`/`world`/`port` are File-context words too, filling fields
    # on their own chapters' aggregates, not Bluebook's — the same
    # "checked against more than one category" shape Lifecycle already has.
    "File"                 => %w[Bluebook Hecksagon World Port Adapter Translation],
    "Bluebook"             => %w[Bluebook],
    "Aggregate"            => %w[Aggregate],
    "Entity"               => %w[Entity],
    "Command"              => %w[Command],
    "Query"                => %w[Query],
    "ValueObject"          => %w[ValueObject],
    "OneOf"                => %w[ValueObject],
    "Lifecycle"            => %w[Aggregate Entity],
    "Policy"               => %w[Policy],
    "ProcessManager"       => %w[ProcessManager],
    "Handler"              => %w[Dispatch],
    "ReadModel"            => %w[ReadModel],
    "Type"                 => [],
    "Hecksagon"            => %w[Hecksagon],
    "World"                => %w[World],
    "DomainPort"           => %w[DomainPort],
    "PortOperation"        => %w[PortOperation],
    # Port/Adapter are their own sibling chapters, each declaring a real
    # aggregate that its own Judge dispatches into.
    "Port"                 => %w[Port],
    "Adapter"              => %w[Adapter],
    # `Translation`'s words fill the Translation aggregate; `TranslationAggregate`'s
    # words fill the nested TranslationAggregate aggregate one level in.
    "Translation"          => %w[Translation],
    "TranslationAggregate" => %w[TranslationAggregate]
  }.freeze

  # Hecksagon/World are sibling chapters, not aggregates inside Bluebook, so
  # fields for File/Hecksagon/World words come from three registries merged.
  # Recurses into each aggregate's own entities too, since Dispatch nests two levels deep.
  def self.all_entities(entity)
    [entity] + entity.entities.flat_map { |piece| all_entities(piece) }
  end

  def self.all_meta_aggregates
    registry     = Hecks::Bluebook::MetaValidator.grammar_registry
    aggregates   = %w[Bluebook Hecksagon World Port Adapter Translation].flat_map do |chapter|
      registry.bluebook(chapter).aggregates
    end
    aggregates + aggregates.flat_map { |a| a.entities.flat_map { |entity| all_entities(entity) } }
  end

  def fill_problem(row, fields)
    landing = CATEGORY_OF.fetch(row[:context])
    name = "#{row[:context]}.#{row[:word]}"
    return "#{name} claims to fill #{row[:fills]}, but #{row[:context]} is a position and holds no record" if landing.empty?
    return if landing.any? { |category| fields.fetch(category).include?(row[:fills]) }

    "#{name} fills #{row[:fills]}, which #{landing.join("/")} does not declare"
  end

  it "fills only fields the language declares" do
    fields = self.class.all_meta_aggregates.to_h { |a| [a.hecks_name, a.attributes.map { |at| at.name.to_s }] }
    filling = KEYWORDS.reject { |row| row[:fills].empty? }

    expect(filling.filter_map { |row| fill_problem(row, fields) }).to be_empty
  end

  def opened_categories = KEYWORDS.map { |row| row[:opens] }.reject(&:empty?).uniq

  it "opens only categories the language declares" do
    declared = self.class.all_meta_aggregates.map(&:hecks_name)

    expect(opened_categories - declared).to be_empty
  end

  # No real bluebook (Banking, Pizzas) ever opens a Vocabulary/Syntax/Keyword/
  # Argument record through the DSL — `SyntaxBoot` seeds Syntax/Keyword/Argument
  # internally instead, so these are excluded from "every dispatched category has a word".
  META_ONLY_CATEGORIES = %w[Vocabulary Syntax Keyword Argument].freeze

  def dispatched_categories
    Hecks::Bluebook::MetaValidator::Plan.for(Hecks::Bluebook::MetaValidator.grammar_registry).names - META_ONLY_CATEGORIES
  end

  it "opens every category the judge dispatches" do
    expect((dispatched_categories - opened_categories).sort).to be_empty,
                                                                "the judge dispatches categories no word opens — a bluebook " \
                                                                "could not declare them"
  end

  # A `pairs` argument can name one field only when its own result (not each
  # pair) lands on a single field — true for the `verbatim`/`elements` shapes,
  # not for `fields`/`sibling`. A `Type` argument fills no field at all.
  def unnameable_fill?(row)
    pairs_names_its_result = row[:kind] == "pairs" && %w[verbatim elements].include?(row[:pairs_shape].to_s)
    (row[:kind] == "pairs" && !pairs_names_its_result) || row[:context] == "Type"
  end

  def fill_naming_problem(row)
    name = "#{row[:context]}.#{row[:keyword]}"
    if !unnameable_fill?(row)
      "#{name} takes an argument that fills nothing" if row[:fills].empty?
    elsif row[:fills] != ""
      "#{name}'s #{row[:kind]} argument names a single field, which it cannot fill"
    end
  end

  it "names what each argument fills, except where nothing can" do
    expect(ARGUMENTS.filter_map { |row| fill_naming_problem(row) }).to be_empty
  end
end
