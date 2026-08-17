require "spec_helper"

# The declared syntax must equal the surface the builders actually answer.
#
# `language/bluebook/syntax.bluebook` says how a bluebook is SPELLED — every
# word, the body it opens, the arguments it takes. Nothing else in this project
# says that. The builders are where the spelling really lives, and before this
# spec the declaration and the builders had never been held to each other —
# a near-miss list could only be kept by hand "because nothing declares
# what the keywords are".
#
# This is the same shape as spec/vocabulary_conformance_spec, for the same
# reason: a declaration nothing reads cannot disagree with anything. It reads
# the syntax out of the meta-domain's IR and holds the live builders to it.
# Declare a word no builder answers and this fails ; grow a builder a word the
# language does not declare and this fails too.
#
# BOTH DIRECTIONS, DELIBERATELY. The one-way version — "everything declared
# exists" — is the one that lets the surface drift: a word added to a builder
# and not to the language is invisible to anything projected from the language,
# which is precisely the class of bug that made the parser unprojectable.
RSpec.describe "the declared syntax" do
  D = Hecksagain::Bluebook::DSL

  def self.judged_meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.syntax = judged_meta.aggregates.find { |a| a.hecks_name == "Syntax" }

  # The same chapter, reachable from inside an example.
  def meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  # EVERY CELL AS TEXT. A member's fields decode back through typed literal
  # decoding on the way out of reconstruction — the same path Attribute#list
  # takes — so `at: "1"` comes back as the Integer 1 and `required: "true"` as
  # true. The language wrote text and the reconstruction is right to decode it;
  # this reads it back as what was written.
  def self.rows(name)
    syntax.value_objects.find { |vo| vo.hecks_name == name }
          .members.map { |row| row.to_h.transform_values(&:to_s) }
  end

  # S14, ADR 0026 — Keyword/Argument are genuine entities of Syntax now,
  # dispatched (not merely declared) so their own `status` really is a
  # lifecycle. `SyntaxBoot.call` reads `KeywordSeed`/`ArgumentSeed` (the
  # still-static seed rows `rows` above still reads directly for Context/
  # Body/ArgumentKind, which stay ordinary closed sets) and dispatches
  # each one through the real admission/lifecycle door, handing back the
  # exact shape `rows` used to read straight off the closed set — nothing
  # below this line needed to change.
  KEYWORDS      = Hecksagain::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
  ARGUMENTS     = Hecksagain::Bluebook::MetaValidator::SyntaxBoot.call[:arguments]
  CONTEXTS      = rows("Context").map { |row| row[:name] }
  BODIES        = rows("Body").map { |row| row[:name] }
  ARGUMENT_KIND = rows("ArgumentKind").map { |row| row[:name] }

  # A word's LIFE decides which gates hold it. Admitted and deprecated
  # words are LIVE — a builder answers them, and every builder⇄row gate
  # below runs over these. A proposed word has no builder YET and a
  # retired one has no builder ANY MORE, so holding either to a builder
  # would make the lifecycle unusable: bin/evolve could never land a
  # proposal green. They get their own gates instead (the last two
  # examples of the word⇄builder section). An absent status reads as
  # admitted — the grown-column convention, see syntax_lifecycle_spec.
  def self.status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s

  def self.live?(row) = %w[admitted deprecated].include?(status_of(row))

  LIVE_KEYWORDS  = KEYWORDS.select { |row| live?(row) }
  LIVE_KEYS      = LIVE_KEYWORDS.map { |row| [row[:word], row[:context]] }.uniq
  LIVE_ARGUMENTS = ARGUMENTS.select { |row| live?(row) && LIVE_KEYS.include?([row[:keyword], row[:context]]) }

  # WHERE EACH CONTEXT'S WORDS ARE ANSWERED. `File` is the only one not answered
  # by a builder — `Hecks.bluebook` is reached through a module — and `Type` is
  # the only one whose "builder" is a mixin rather than a class, because the type
  # position inherits whichever `list_of`/`one_of` the enclosing builder has.
  #
  # `OneOf` shares ValueObjectBuilder with `ValueObject`: `one_of` instance_evals
  # its block on the builder itself, so the two contexts are one Ruby object.
  # That is why the completeness check below groups contexts BY BUILDER rather
  # than comparing each context to a class of its own.
  BUILDER = {
    "File"           => Hecks,
    "Bluebook"       => D::BluebookBuilder,
    "Aggregate"      => D::AggregateBuilder,
    "Entity"         => D::EntityBuilder,
    "Command"        => D::CommandBuilder,
    "Query"          => D::QueryBuilder,
    "ValueObject"    => D::ValueObjectBuilder,
    "OneOf"          => D::ValueObjectBuilder,
    "Lifecycle"      => D::LifecycleBuilder,
    "Policy"         => D::PolicyBuilder,
    "ProcessManager" => D::ProcessManagerBuilder,
    "Handler"        => D::ProcessManagerBuilder::HandlerBuilder,
    "ReadModel"      => D::ReadModelBuilder,
    "Type"           => D::AttributeCollector,
    "Hecksagon"      => D::HecksagonBuilder,
    "World"          => D::WorldBuilder,
    "DomainPort"     => D::DomainPortBuilder,
    "PortOperation"  => D::PortOperationBuilder
  }.freeze

  # PUBLIC AND NOT A WORD — each with its reason, because an unexplained
  # allowlist is how a retired word goes on passing.
  #
  #   build / attributes / closed_sets / dispatches / add_aggregate_head
  #     a builder's own bookkeeping. `build` is the closing act `self.build`
  #     calls ; the rest are collections read by whoever owns them. None is ever
  #     typed in a bluebook.
  #
  #   boot / with_registry / current_registry
  #     the loading and runtime facade on `Hecks`, not declarations at all.
  #
  #   port / adapter / data_translation
  #     SIBLING ARTIFACTS, and the stated scope exclusion — each has its own file
  #     extension, its own builder and its own load step. A parser projected from
  #     this table reads `.bluebook`.
  #
  #   hecksagon / world (as File-level ENTRY POINTS, not as artifacts)
  #     no longer excluded — see the `hecksagon`/`world` rows syntax.bluebook now
  #     declares, and the Hecksagon/World builder mappings above. What stays
  #     excluded is each body's OPEN verb vocabulary (method_missing/ConstShim),
  #     named per-context below rather than by blanket File-level exclusion.
  NOT_A_WORD = {
    "Bluebook"  => {
      classification: "an attr_reader BluebookBuilder.build reads when merging one chapter across files"
    },
    "File"      => {
      boot:             "the runtime facade, not a declaration",
      with_registry:    "the runtime facade, not a declaration",
      current_registry: "the runtime facade, not a declaration",
      as_caller:        "the runtime facade, not a declaration",
      port:             "a sibling artifact — .port has its own builder and its own file",
      adapter:          "a sibling artifact — .adapter has its own builder and its own file",
      data_translation: "a sibling artifact — translations/ has its own builder and its own file"
    },
    "Hecksagon" => {
      binds:             "the builder's own collected Bind records, read by whoever owns them",
      subscriptions:     "the builder's own collected subscription strings, read by whoever owns them",
      framework_members: "the builder's own collected framework-member names, read by whoever owns them",
      # THE OPEN VERB CATCH-ALL, DOMAIN-LEVEL. `persisted_by "Heki"` bare
      # (no aggregate) reaches HecksagonBuilder#method_missing the same
      # way World's own does — the verb is whichever bind-shaped word a
      # domain declares, not a closed set this table could enumerate.
      method_missing:    "the open domain-level-default-bind catch-all — same boundary as World's own"
    },
    "World"     => {
      # THE OPEN VERB-SETTINGS CATCH-ALL. `posted_by("Carrier") { office
      # "EC1" }` reaches WorldBuilder#method_missing — the verb is
      # whichever port a domain declares, not a closed set this table
      # could enumerate. Same boundary as .hecksagon's Const.verb(...)
      # form, named in syntax.bluebook's own comment on the `world` row.
      method_missing: "the open port-verb settings catch-all — .world's adapter-binding " \
                      "vocabulary is per-application, not a fixed set the language can enumerate"
    },
    "*"         => {
      build:              "the builder's closing act, called by self.build",
      attributes:         "AttributeCollector's collection, read by whoever owns it",
      closed_sets:        "AttributeCollector's synthesised sets, installed by the aggregate",
      dispatches:         "HandlerBuilder's collection, read by ProcessManagerBuilder",
      add_aggregate_head: "ReadModelBuilder's own build calls it; nothing types it"
    }
  }.freeze

  # THE ONE PLACE A SPELLING AND A RUBY SIGNATURE DIVERGE. `transition` takes one
  # Hash and deletes `:from` out of it, so `from:` is written exactly like a
  # keyword argument and received as a reserved key of the pairs argument. The
  # language declares the SPELLING, which is what a parser reads, so it declares
  # `from` as named — and this is the exception that lets the signature check
  # agree.
  RESERVED_KEY = { %w[transition Lifecycle] => %w[from], %w[transition ProcessManager] => %w[from] }.freeze

  def self.words_answered_by(context)
    builder = BUILDER.fetch(context)
    listed  = if builder.is_a?(Module) && !builder.is_a?(Class) && builder.equal?(Hecks)
                builder.methods - Module.methods
              elsif builder.is_a?(Class)
                builder.public_instance_methods - Object.public_instance_methods
              else
                builder.public_instance_methods(false)
              end
    listed - NOT_A_WORD.fetch("*").keys - NOT_A_WORD.fetch(context, {}).keys
  end

  def method_for(word, context)
    builder = BUILDER.fetch(context)
    return builder.method(word) if builder.equal?(Hecks)

    builder.instance_method(word)
  end

  def declared_in(context) = LIVE_KEYWORDS.select { |row| row[:context] == context }

  # ---------------------------------------------------------------- the cells

  it "spells every cell with a word the language admits" do
    expect(KEYWORDS.map { |row| row[:context] }.uniq - CONTEXTS).to be_empty
    expect(KEYWORDS.map { |row| row[:body] }.uniq - BODIES).to be_empty
    expect(ARGUMENTS.map { |row| row[:kind] }.uniq - ARGUMENT_KIND).to be_empty
    expect(ARGUMENTS.map { |row| row[:context] }.uniq - CONTEXTS).to be_empty
  end

  # `admits:` is a link the language can make and a closed set is not a root, so
  # nothing resolves it for a value object nobody instantiates. Checked here
  # instead, or the three `admits:` in syntax.bluebook would be decoration.
  it "holds every admits-bearing column to the set it names" do
    # S14, ADR 0026 — Keyword/Argument are genuine entities of Syntax
    # now, not value objects — found through `.entities`, same as Syntax
    # (below) reaches every other real entity.
    shape = ->(name) { self.class.syntax.entities.find { |e| e.hecks_name == name } }

    { "Keyword"  => { context: "Context", body: "Body" },
      "Argument" => { context: "Context", kind: "ArgumentKind" } }.each do |vo, links|
      links.each do |field, set|
        declared = shape.call(vo).attributes.find { |a| a.name.to_s == field.to_s }
        expect(declared.admits).to eq("Syntax::#{set}"),
                                   "#{vo}.#{field} should admit Syntax::#{set}"
      end
    end
  end

  it "enters every context it declares, and declares words for every context it enters" do
    entered = KEYWORDS.map { |row| row[:inner] }.reject(&:empty?).uniq
    spoken  = KEYWORDS.map { |row| row[:context] }.uniq

    # TWO CONTEXTS ARE NOT ENTERED BY A WORD, for two different reasons. `File`
    # is the outside of every body — nothing opens it. `Type` is the second
    # ARGUMENT of `attribute` rather than a body, so it is entered by a position
    # and never by a `do`. Every other context must be opened by something, or
    # no bluebook could ever type a word in it.
    expect((spoken - entered).sort).to eq(%w[File Type]),
                                       "a context is spoken in but nothing opens it"
    expect(entered - spoken).to be_empty,
                                "a word opens a body no word may be typed in"
  end

  # ------------------------------------------------------- word ⇄ builder

  CONTEXTS.each do |context|
    describe context do
      it "declares only words the builder answers" do
        undeclared = declared_in(context).map { |row| row[:word].to_sym }.uniq
                                         .reject { |word| BUILDER.fetch(context).equal?(Hecks) ? Hecks.respond_to?(word) : BUILDER.fetch(context).method_defined?(word) }

        expect(undeclared).to be_empty,
                              "#{context} declares #{undeclared.inspect}, which " \
                              "#{BUILDER.fetch(context)} does not answer"
      end
    end
  end

  # THE OTHER DIRECTION, GROUPED BY BUILDER because two contexts can share one
  # (ValueObject and OneOf) and because AttributeCollector's words are MIXED IN
  # to five builders rather than answered by a builder of their own.
  #
  # A mixed-in word counts as declared for a builder only while the builder does
  # not SHADOW it — which is not a technicality. ValueObjectBuilder defines
  # `one_of(&block)` over AttributeCollector's `one_of(*values)`, so inside a
  # value-object body the inline type form is unreachable and `attribute :size,
  # one_of("small", "large")` raises. That asymmetry is real, and the ownership
  # test below is what keeps it declared rather than assumed.
  BUILDER.group_by { |_, builder| builder }.each do |builder, pairs|
    contexts = pairs.map(&:first)
    next if builder.equal?(D::AttributeCollector)

    it "declares every word #{builder} answers (#{contexts.join(', ')})" do
      declared = contexts.flat_map { |ctx| declared_in(ctx).flat_map { |row| [row[:word], row[:was].to_s].reject(&:empty?) } }
                         .map(&:to_sym).uniq

      if builder.is_a?(Class) && builder.include?(D::AttributeCollector)
        declared += LIVE_KEYWORDS.select { |row| row[:context] == "Type" }
                                 .map { |row| row[:word].to_sym }
                                 .select { |word| builder.instance_method(word).owner.equal?(D::AttributeCollector) }
      end

      answered = contexts.flat_map { |ctx| self.class.words_answered_by(ctx) }.uniq

      expect((answered - declared).sort).to be_empty,
                                            "#{builder} answers words the language does not declare — " \
                                            "a bluebook could use them and nothing projected from the " \
                                            "language would know they exist"
    end
  end

  # THE RENAME COLUMN'S OWN GATES. A live row carrying `was:` is a word
  # the language RESPELLED — and the promise of the column is that the
  # old era keeps booting: the builder answers both spellings, the old
  # spelling is not smuggled back in as its own row, and nothing renames
  # a word to itself.
  it "answers every renamed word in both its spellings" do
    LIVE_KEYWORDS.reject { |row| row[:was].to_s.empty? }.each do |row|
      answered = self.class.words_answered_by(row[:context])
      expect(answered).to include(row[:word].to_sym),
                          "#{row[:context]}.#{row[:word]} — the new spelling has no builder"
      expect(answered).to include(row[:was].to_sym),
                          "#{row[:context]}.#{row[:word]} was #{row[:was]}, and the old " "spelling stopped parsing — a rename never strands the old era"
      expect(row[:was]).not_to eq(row[:word]), "#{row[:context]}.#{row[:word]} renames itself"
    end
  end

  it "keeps no renamed-away spelling as a row of its own" do
    respelled = KEYWORDS.reject { |row| row[:was].to_s.empty? }
                        .map { |row| [row[:was], row[:context]] }
    ghosts = respelled & KEYWORDS.map { |row| [row[:word], row[:context]] }

    expect(ghosts).to be_empty,
                      "old spellings declared twice — as was: and as a row: #{ghosts.inspect}"
  end

  # THE LIFECYCLE'S OWN TWO DIRECTIONS. A proposed word is declared and
  # not yet implemented — a builder already answering it means it earned
  # admission, and the row should say so. A retired word is the reverse:
  # a builder still answering it means it never actually left.
  it "leaves every proposed word unanswered — answered means admit it" do
    early = KEYWORDS.select { |row| self.class.status_of(row) == "proposed" }
                    .select { |row| self.class.words_answered_by(row[:context]).include?(row[:word].to_sym) }

    expect(early).to be_empty,
                     early.map { |row| "#{row[:context]}.#{row[:word]}" }.join(", ") +
                     " — proposed, but the builder already answers; run bin/evolve admit"
  end

  it "leaves every retired word unanswered — answered means it never left" do
    lingering = KEYWORDS.select { |row| self.class.status_of(row) == "retired" }
                        .select { |row| self.class.words_answered_by(row[:context]).include?(row[:word].to_sym) }

    expect(lingering).to be_empty,
                         lingering.map { |row| "#{row[:context]}.#{row[:word]}" }.join(", ") +
                         " — retired, but the builder still answers"
  end

  # ------------------------------------------------------ arguments ⇄ signature

  it "joins every argument row to a word" do
    keys    = KEYWORDS.map { |row| [row[:word], row[:context]] }.uniq
    widowed = ARGUMENTS.map { |row| [row[:keyword], row[:context]] }.uniq - keys

    expect(widowed).to be_empty, "argument rows joining to no keyword: #{widowed.inspect}"
  end

  it "declares every keyword argument each word's builder takes, and no other" do
    LIVE_ARGUMENTS.group_by { |row| [row[:keyword], row[:context]] }.each do |(word, context), args|
      params  = method_for(word, context).parameters
      taken   = params.select { |kind, _| %i[key keyreq].include?(kind) }.map { |_, name| name.to_s }
      spelled = args.reject { |row| row[:named].empty? }.map { |row| row[:named] }.uniq
      allowed = taken + RESERVED_KEY.fetch([word, context], [])

      expect((spelled - allowed).sort).to be_empty,
                                          "#{context}.#{word} declares #{(spelled - allowed).inspect}, " \
                                          "which its builder does not take"
      expect((taken - spelled).sort).to be_empty,
                                        "#{context}.#{word}'s builder takes #{(taken - spelled).inspect}, " \
                                        "which the language does not declare"
    end
  end

  it "declares no more positionals than each word's builder takes" do
    LIVE_ARGUMENTS.group_by { |row| [row[:keyword], row[:context]] }.each do |(word, context), args|
      positional = args.reject { |row| row[:at].empty? }
      next if positional.empty?

      params = method_for(word, context).parameters
      next if params.any? { |kind, _| kind == :rest } # `one_of("small", "large")` is variadic

      room = params.count { |kind, _| %i[req opt].include?(kind) }
      # An inline hash at a call site binds to a positional Hash parameter or to
      # a **keyrest, and the SPELLING does not distinguish them — `where(a: 1)`
      # and `member a: 1` are typed identically and land differently.
      room += 1 if positional.any? { |row| row[:kind] == "pairs" } &&
                   params.any? { |kind, _| kind == :keyrest }

      expect(positional.map { |row| row[:at] }.map(&:to_i).max).to be <= room,
                                                                   "#{context}.#{word} declares more positionals than its builder takes"
    end
  end

  # THE DANGEROUS DIRECTION. A builder DEMANDING an argument the language calls
  # optional is a bluebook that parses everywhere and loads nowhere, so this is
  # checked one way on purpose: an optional parameter may be declared required,
  # but a required one may never be declared optional.
  it "never calls an argument optional that the builder demands" do
    LIVE_ARGUMENTS.group_by { |row| [row[:keyword], row[:context]] }.each do |(word, context), args|
      params = method_for(word, context).parameters

      params.each_with_index do |(kind, name), index|
        next unless kind == :req

        row = args.find { |candidate| candidate[:at] == (index + 1).to_s }
        next if row.nil?

        expect(row[:required]).to eq("true"),
                                  "#{context}.#{word}'s #{name} is required by the builder and " \
                                  "declared optional"
      end

      params.select { |kind, _| kind == :keyreq }.each do |_, name|
        row = args.find { |candidate| candidate[:named] == name.to_s }
        next if row.nil?

        expect(row[:required]).to eq("true"),
                                  "#{context}.#{word}'s #{name}: is required by the builder and " \
                                  "declared optional"
      end
    end
  end

  # `selects` IS THE OPERATION `sets`' own named argument means — the same
  # field `rust/parser/src/keywords.rs`'s `ArgumentRow.selects` already
  # carries (`"op=set"`, `"op=append"`, ...), read here for the first time
  # (whole-project table-unification survey, item #1 — confirmed via grep
  # that nothing consumed it until now). `sets` is the ONLY keyword that
  # ever populates it, so this is complete coverage of every non-empty
  # `selects` row in the entire table, not a `sets`-only special case that
  # happens to cover everything today.
  #
  # `named` (the kwarg's own SPELLING) is already held to `CommandBuilder#
  # sets`'s parameter list by "declares every keyword argument..." above —
  # this checks the one fact that check cannot: `to:` is the one kwarg
  # whose OWN NAME differs from the op it selects (`selects: "op=set"`),
  # so `named == op` alone would silently pass even if the language and the
  # builder disagreed about what `to:` actually DOES.
  it "selects the same op CommandBuilder::KWARG_TO_OP maps each named argument to" do
    sets_rows = ARGUMENTS.select { |row| row[:keyword] == "sets" && row[:context] == "Command" && !row[:selects].empty? }
    expect(sets_rows).not_to be_empty

    live = D::CommandBuilder::KWARG_TO_OP.transform_keys(&:to_s).transform_values(&:to_s)

    sets_rows.each do |row|
      declared_op = row[:selects].delete_prefix("op=")
      expect(live[row[:named]]).to eq(declared_op),
                                   "sets' #{row[:named]}: selects op=#{declared_op} in the language, " \
                                   "but CommandBuilder::KWARG_TO_OP maps it to #{live[row[:named]].inspect}"
    end
    expect(sets_rows.map { |row| row[:named] }).to match_array(live.keys)
  end

  # ---------------------------------------------------------- words ⇄ language

  # A context's category is where its `fills` must land. `Lifecycle` has none of
  # its own — it is a DECLARED FOLD onto whichever of Aggregate or Entity opened
  # it — so its words are checked against both. `Type` is a position, not a
  # record, so nothing it declares may claim to fill anything.
  CATEGORY_OF = {
    # `hecksagon`/`world` are File-context words too, and fill fields on
    # THEIR OWN chapters' aggregates, not Bluebook's — broadened the same
    # way Lifecycle already checks against two categories, not one.
    "File"           => %w[Bluebook Hecksagon World],
    "Bluebook"       => %w[Bluebook],
    "Aggregate"      => %w[Aggregate],
    "Entity"         => %w[Entity],
    "Command"        => %w[Command],
    "Query"          => %w[Query],
    "ValueObject"    => %w[ValueObject],
    "OneOf"          => %w[ValueObject],
    "Lifecycle"      => %w[Aggregate Entity],
    "Policy"         => %w[Policy],
    "ProcessManager" => %w[ProcessManager],
    "Handler"        => %w[Dispatch],
    "ReadModel"      => %w[ReadModel],
    "Type"           => [],
    "Hecksagon"      => %w[Hecksagon],
    "World"          => %w[World],
    "DomainPort"     => %w[DomainPort],
    "PortOperation"  => %w[PortOperation]
  }.freeze

  # Hecksagon and World are SIBLING chapters, not aggregates inside
  # Bluebook — so the fields a File/Hecksagon/World-context word may fill
  # come from three separate chapters' registries, merged. A duplicate
  # aggregate name across chapters is not a case this project has (each
  # chapter's own aggregate names are already distinct), so a plain merge
  # is exact, not an approximation.
  # S17, ADR 0026 — includes each aggregate's own ENTITIES too, not only
  # the aggregates themselves — and recursively, since Dispatch nests two
  # levels deep (inside Handler, inside ProcessManager). Member (nested
  # under ValueObject) is a real construct a keyword can legitimately
  # open — `member` does, inside `one_of` — even though it is no longer
  # a top-level aggregate with a bare verb of its own. An entity answers
  # to `.hecks_name`/`.attributes` the same way an aggregate does, so
  # nothing downstream has to know which one it got.
  def self.all_entities(entity)
    [entity] + entity.entities.flat_map { |piece| all_entities(piece) }
  end

  def self.all_meta_aggregates
    registry     = Hecksagain::Bluebook::MetaValidator.grammar_registry
    aggregates   = %w[Bluebook Hecksagon World].flat_map { |chapter| registry.bluebook(chapter).aggregates }
    aggregates + aggregates.flat_map { |a| a.entities.flat_map { |entity| all_entities(entity) } }
  end

  it "fills only fields the language declares" do
    fields = self.class.all_meta_aggregates.to_h { |a| [a.hecks_name, a.attributes.map { |at| at.name.to_s }] }

    KEYWORDS.reject { |row| row[:fills].empty? }.each do |row|
      landing = CATEGORY_OF.fetch(row[:context])
      expect(landing).not_to be_empty,
                             "#{row[:context]}.#{row[:word]} claims to fill #{row[:fills]}, but " \
                             "#{row[:context]} is a position and holds no record"
      expect(landing.any? { |category| fields.fetch(category).include?(row[:fills]) }).to be(true),
                                                                                          "#{row[:context]}.#{row[:word]} fills #{row[:fills]}, which " \
                                                                                          "#{landing.join('/')} does not declare"
    end
  end

  it "opens only categories the language declares" do
    declared = self.class.all_meta_aggregates.map(&:hecks_name)
    opened   = KEYWORDS.map { |row| row[:opens] }.reject(&:empty?).uniq

    expect(opened - declared).to be_empty
  end

  # EVERY DISPATCHED CATEGORY HAS A WORD, or a domain cannot declare it.
  #
  # The judge's plan is exactly the categories a bluebook can put records in
  # (Vocabulary declares no commands and so is not in it — it is
  # the language's own declaration, written with `aggregate` like anything
  # else). If one of them had no word opening it, the language would hold a
  # category no bluebook could reach.
  #
  # S14, ADR 0026 — Syntax/Keyword/Argument are named here for the SAME
  # reason Vocabulary always was, just reached a different way: Syntax
  # now declares real commands (`Declare`/`Keyword`/`Argument`), so
  # `plan.names` finds it (and its own entities, Keyword/Argument)
  # unlike Vocabulary — but no real bluebook (Banking, Pizzas) ever
  # opens a "Syntax"/"Keyword"/"Argument" record through the DSL ; the
  # only caller that ever dispatches them is `SyntaxBoot`, a dedicated,
  # internal mechanism that seeds the language's OWN grammar table from
  # its own still-static `KeywordSeed`/`ArgumentSeed` rows, not
  # something any domain's own bluebook file could reach.
  META_ONLY_CATEGORIES = %w[Vocabulary Syntax Keyword Argument].freeze

  it "opens every category the judge dispatches" do
    plan = Hecksagain::Bluebook::MetaValidator::Plan.for(
      Hecksagain::Bluebook::MetaValidator.grammar_registry
    ).names - META_ONLY_CATEGORIES
    opened = KEYWORDS.map { |row| row[:opens] }.reject(&:empty?).uniq

    expect((plan - opened).sort).to be_empty,
                                    "the judge dispatches categories no word opens — a bluebook " \
                                    "could not declare them"
  end

  # A `pairs` argument decides which field EACH PAIR lands in from the pair's
  # own key, so one cell cannot name that — UNLESS the pairs argument's own
  # RESULT (the whole compound or list it builds) lands on one real field,
  # which two of the four `pairs_shape`s do: `verbatim` (`dispatch`'s `with:`
  # → `with_spec`, captured as-is) and `elements` (`where` → `wheres`, one
  # new element per pair). `fields` (a pair's key/value become two NAMED
  # SUB-FIELDS of a compound something else already fills) and `sibling` (the
  # key names a field of another, already-declared construct) still cannot
  # name a single field here, the original reasoning unchanged. A `Type`
  # argument fills no field at all — a type is not a field. Everything else
  # names exactly one.
  it "names what each argument fills, except where nothing can" do
    ARGUMENTS.each do |row|
      pairs_names_its_result = row[:kind] == "pairs" && %w[verbatim elements].include?(row[:pairs_shape].to_s)
      unnameable = (row[:kind] == "pairs" && !pairs_names_its_result) || row[:context] == "Type"

      if unnameable
        expect(row[:fills]).to eq(""),
                               "#{row[:context]}.#{row[:keyword]}'s #{row[:kind]} argument names a " \
                               "single field, which it cannot fill"
      else
        expect(row[:fills]).not_to be_empty,
                                   "#{row[:context]}.#{row[:keyword]} takes an argument that fills nothing"
      end
    end
  end
end
