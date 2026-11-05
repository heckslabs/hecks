require_relative "fuzzing/target_capabilities"
require_relative "corpus/adapters"
require_relative "corpus/generated_key"
require_relative "corpus/listing"
require_relative "corpus/routes"
require_relative "corpus/rust"
require_relative "corpus/sources"
require_relative "corpus/worlds"
require_relative "sentence_form"

module Hecks
  # The corpus: every place in this repo that holds a real domain, named once.
  # Plain Dir/File only — the tools require this before booting anything.
  module Corpus
    ROOT = File.expand_path("../..", __dir__).freeze

    Member = Struct.new(:stem, :kind, :path)

    # **One domain per directory** — its bluebooks sit in `<dir>/bluebook/`
    # or directly in `<dir>` (see `bluebook_files`). Stemmed by directory.
    DIRECTORY_KINDS = {
      example:   "examples/*",
      stress:    "qa/stress_domains/*",
      semantics: "spec/corpus/semantics/domains/*",
      # The Hecks domain (ADR 0080): its bluebooks share one namespace and one hecksagon, so
      # they load together, as a directory, never file by file.
      hecks:     "lib/hecks/hecks",
      # The Coder and Fixer domains keep their bluebook beside their hecksagon in their own folder.
      coder:     "lib/hecks/coder",
      fixer:     "lib/hecks/fixer",
      # The PipelineBoard domain keeps its bluebook beside its hecksagon and adapters.
      board:     "lib/hecks/pipeline_board",
      # The Pipeline domain: one passage per change, moved by the other domains' events.
      pipeline:  "lib/hecks/pipeline",
      # The Agents domain: the roles a session is pinned to, their handoffs and reviews.
      agents:    "lib/hecks/agents",
      # The Catcher domain: raw actions seen outside any declared command, kept, judged and acted
      # on.
      catcher:   "lib/hecks/catcher",
      # A package vendored via `attaches ... from: :vendor` — nested inside the
      # consuming example's own checkout, not this gem's own framework/bluebook/.
      vendored:  "examples/*/vendor/embryonaut_bluebooks/*"
    }.freeze

    # **One bluebook per file**. Stemmed by the path below the glob's fixed
    # prefix, so a nested fixture keeps its subdirectory (`eras/base`)
    # and never collides with a same-named file elsewhere in the kind.
    FILE_KINDS = {
      grammar:      "lib/hecks/grammar/*.bluebook",
      framework:    "lib/hecks/framework/bluebook/*.bluebook",
      qa:           "lib/hecks/quality_control/*.bluebook",
      language:     "lib/hecks/language/**/*.bluebook",
      deploy:       "lib/hecks/deploy/bluebook/*.bluebook",
      site:         "lib/hecks/site/bluebook/*.bluebook",
      rails_app:    "lib/hecks/rails_app/bluebook/*.bluebook",
      tickets:      "lib/hecks/tickets/bluebook/*.bluebook",
      composer:     "lib/hecks/composer/bluebook/*.bluebook",
      tenancy:      "lib/hecks/tenancy/bluebook/*.bluebook",
      gate:         "lib/hecks/gate/*.bluebook",
      questions:    "lib/hecks/questions/*.bluebook",
      bulk:         "lib/hecks/bulk/bluebook/*.bluebook",
      sme:          "lib/hecks/sme/bluebook/*.bluebook",
      # The CI bluebooks keep their bluebook beside their hecksagon, not under a `bluebook/` folder.
      # CiPipeline is attachable; CiSpeed boots from its own directory; CiWorkflows is the client
      # whose rows project into .github/workflows.
      ci_pipeline:  "lib/hecks/ci_pipeline/*.bluebook",
      ci_speed:     "lib/hecks/ci_speed/*.bluebook",
      ci_workflows: "lib/hecks/ci_workflows/*.bluebook",
      fixture:      "spec/fixtures/**/*.bluebook"
    }.freeze

    KINDS = (DIRECTORY_KINDS.keys + FILE_KINDS.keys).freeze

    extend Adapters
    extend Listing
    extend Rust
    extend Sources
    extend Worlds

    module_function

    # Lists corpus members of the given kinds (every kind, by default).
    #
    # @param kinds [Array<Symbol>] corpus kinds to include, from `KINDS`; every kind
    #   when empty
    # @param root [String] repository root to search under
    # @return [Array<Member>] matching members
    # @raise [ArgumentError] if `kinds` names a kind not in `KINDS`
    def members(*kinds, root: ROOT)
      kinds = KINDS if kinds.empty?
      kinds.flat_map { |kind| kind_members(kind, root) }
    end

    # What a boot loads for a member — a directory kind's bluebook
    # directory, or a file kind's own file.
    #
    # @param member [Member] the corpus member
    # @return [String, nil] the path to boot, or nil when a directory member holds
    #   no bluebook
    def source_of(member)
      DIRECTORY_KINDS.key?(member.kind) ? bluebook_dir(member.path) : member.path
    end

    # The route a repo-relative path takes instead of the sweep — the
    # first one it matches — or `nil` when the sweep boots it.
    #
    # @param relative_path [String] a corpus member's path, relative to the repo root
    # @return [Route, nil] the first matching route, or nil when the sweep boots it
    def route_for(relative_path)
      ROUTES.find { |route| route.pattern.match?(relative_path) }
    end

    # Every kind hecks model_check walks: excludes language/deploy (checked
    # elsewhere) and anything a route already sends to its own destination.
    MODEL_CHECK_KINDS = %i[example grammar framework vendored qa stress fixture hecks].freeze

    # Every corpus member `hecks model_check` and `spec/model_check_spec.rb` walk.
    #
    # @param root [String] repository root to search under
    # @return [Array<Member>] members of `MODEL_CHECK_KINDS`, less any routed elsewhere
    def model_check_members(root: ROOT)
      members(*MODEL_CHECK_KINDS, root: root).reject { |member| route_for(member.path.delete_prefix("#{root}/")) }
    end

    # **The ledger sweeps itself** — its own bluebook is a domain like any
    # other, and the one rotation member that is neither an example nor a
    # stress domain.
    ROTATION_LEDGER = { "quality_control" => "qa/bluebook" }.freeze

    # What the QA rotation is made of — every example and stress domain,
    # plus the ledger, as `reference => repo-relative path` — derived, not hand-kept.
    #
    # @param root [String] repository root to search under
    # @return [Hash{String => String}] each rotation member's stem/reference mapped
    #   to its repo-relative path
    def rotation_targets(root: ROOT)
      members(:example, :stress, root: root)
        .to_h { |member| [member.stem, member.path.delete_prefix("#{root}/")] }
        .merge(ROTATION_LEDGER)
    end

    # Every bootable domain in the project — any directory holding a
    # `.bluebook` no route sends elsewhere (a `bluebook/` folder stands for its parent),
    # less module folders, which their parent's bluebook stands for.
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] absolute paths of every sweepable domain directory
    def sweepable_domains(root = ROOT)
      Dir.chdir(root) do
        swept = Dir.glob("**/*.bluebook").reject { |path| route_for(path) || module_bluebook?(path) }
        dirs = swept.map { |path| owning_dir(File.dirname(path)) }
        dirs.uniq.sort.map { |dir| File.join(root, dir) }
      end
    end

    # The domain directory a bluebook directory stands for: a `bluebook/` folder is its parent.
    def owning_dir(dir) = File.basename(dir) == "bluebook" ? File.dirname(dir) : dir

    # A bluebook line that opens a `domain_module`.
    MODULE_OPENING = /^\s*domain_module\b/

    # Whether a bluebook is a module folder's (ADR 0163): it opens a `domain_module` of the parent's
    # bluebook, so its folder is no domain on its own and cannot boot alone.
    def module_bluebook?(path)
      File.basename(path, ".bluebook") == File.basename(File.dirname(path)) && File.read(path).match?(MODULE_OPENING)
    end

    # Sweepable domains a fuzz cannot boot from its copy, by repo-relative directory, each with
    # the reason. A fuzz boots a tmpdir copy of a domain to isolate its state.
    FUZZ_UNBOOTABLE = {
      "lib/hecks/hecks"                                           => "the gem's own bluebook; model_check covers it",
      "spec/fixtures/qa_discover_external_domains/projects/hecks" => "declares the reserved bluebook name `Hecks`",
      "spec/fixtures/sentence/cms_page"                           => "holds one bluebook twice, as sentences and as Ruby; " \
                                                                     "sentence_form_spec compares the pair"
    }.freeze

    # Every sweepable domain a fuzz can boot: `sweepable_domains` less `FUZZ_UNBOOTABLE`.
    #
    # @param root [String] repository root to search under
    # @return [Array<String>] absolute paths of the domain directories `hecks fuzz` sweeps
    def fuzzable_domains(root = ROOT)
      sweepable_domains(root) - FUZZ_UNBOOTABLE.keys.map { |dir| File.join(root, dir) }
    end

    # The domain directory a member stands for, spelled the way
    # `sweepable_domains` spells it: a `bluebook/` folder is its parent.
    #
    # @param member [Member] the corpus member
    # @return [String] the member's owning domain directory path
    def domain_dir_of(member)
      dir = File.directory?(member.path) ? member.path : File.dirname(member.path)
      owning_dir(dir)
    end

    # The bluebook a bluebook declares — `Hecks.bluebook "<Name>"`, or `Domain: <name>` for a file
    # written as sentences — read off the file rather than guessed from its name, since the two
    # can differ.
    #
    # @param bluebook_path [String, Array<String>] a `.bluebook` file path, or an
    #   array whose first element is used
    # @return [String, nil] the declared bluebook name, or nil when the file never
    #   declares one
    def bluebook_name_of(bluebook_path)
      SentenceForm.declaration_name(Array(bluebook_path).first)
    end
  end
end
