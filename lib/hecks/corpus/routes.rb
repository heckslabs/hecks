module Hecks
  module Corpus
    # A route sends what the sweep does not boot elsewhere; each entry's
    # `check` (:named_in, :gitignored, :gap) is verified by
    # spec/corpus_accounting_spec.rb, matched in order.
    Route = Struct.new(:pattern, :check, :destination, :names, :why)

    ROUTES = [
      Route.new(%r{\Atmp/}, :gitignored, ".gitignore", "tmp/",
                "scratch output — generated and mined candidate domains, fuzz failures — never committed"),
      Route.new(%r{/\.aws-sam/}, :gitignored, ".gitignore", ".aws-sam/",
                "SAM build output — a vendored copy of real sources, never committed"),
      Route.new(%r{/data/eras/}, :gitignored, ".gitignore", "**/data/eras/",
                "era snapshots a file adapter writes at runtime, never committed"),
      Route.new(%r{\Arust/}, :named_in, "rust/parser/tests/gates.rs", :each_file,
                "the Rust parser's own fixtures, each loaded by its gate tests"),
      Route.new(%r{/translations/}, :named_in, "spec/translation/committed_edges_spec.rb", "bluebook/translations",
                "translation edges, not chapters; each must load, chain era to era, and end at the storage " \
                "shape its bluebook declares today"),
      Route.new(%r{\Alib/hecks/forms/examples/}, :named_in, "spec/forms/app_spec.rb", :each_file,
                "a Forms presentation config wearing the .bluebook extension"),
      Route.new(%r{\Aspec/fixtures/eras/}, :named_in, "spec/runtime/storage_shape_spec.rb", "fixtures/eras",
                "deliberately conflicting versions of one domain; each must classify as the verdict " \
                "its filename declares (bump_* / same_*)"),
      Route.new(%r{\Aspec/fixtures/model_check/}, :named_in, "spec/model_check_spec.rb", :each_file,
                "domains broken on purpose; each must produce exactly the finding kinds it is built to trigger"),
      Route.new(%r{\Aspec/fixtures/site/editor_chapters/domain/}, :named_in, "spec/site_cms_editor_chapters_spec.rb",
                "site/editor_chapters",
                "two chapters that both declare a Category, so the editor must tell them apart; one SQLite " \
                "file keeps tables by bare aggregate name, which cannot hold both, so the sweep cannot boot it"),
      # hecks fuzz sweeps it too, once Fuzzing::Replay coerces value-object args
      # before recomputing givens — today it doesn't, so this given reads as
      # wrongly admitted.
      Route.new(%r{\Aspec/corpus/asks/}, :named_in, "spec/policy_ask_spec.rb", "spec/corpus/asks",
                "a corpus-owned domain whose ports have no adapter, so an ask is refused; its frozen " \
                "targets are held to the Ruby runtime there and to the Rust policy table in rust/codegen"),
      Route.new(%r{\Aspec/fixtures/sentence/cms_page/sentence_form\.bluebook\z}, :named_in, "spec/sentence_form_spec.rb",
                :each_file,
                "a chapter written as sentences, which only a built hecks-parse can read; the sweep boots its " \
                "Ruby twin instead, and spec/sentence_form_spec.rb compares the pair byte for byte"),
      Route.new(%r{\Aspec/fixtures/sentence/orders/}, :named_in, "spec/sentence_form_spec.rb", :each_file,
                "a chapter written as sentences beside its Ruby twin, whose policies ask the outside and " \
                "wait for its answers; model_check wants the hecksagon that declares that port, which the " \
                "sweep does not load. The spec compares each pair and spec/sentence_examples_spec.rb runs " \
                "its examples against the hecksagon"),
      Route.new(%r{\Aspec/fixtures/rust_host/}, :named_in, "rust/host/src/web/commerce.rs", "checkout_fixture",
                "the Rust host's checkout fixture, pinned by its web and /api tests"),
      Route.new(%r{\Apackages/hecks-rails/spec/fixtures/}, :named_in, "packages/hecks-rails/spec/support/ledger_app.rb",
                :each_file,
                "the hecks-rails gem's fixture app; its own specs boot it under Rails, which this sweep cannot")
    ].freeze
  end
end
