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
      # hecks fuzz sweeps it too, once Fuzzing::Replay coerces value-object args
      # before recomputing givens — today it doesn't, so this given reads as
      # wrongly admitted.
      Route.new(%r{\Aspec/fixtures/rust_host/}, :named_in, "rust/host/src/web/commerce.rs", "checkout_fixture",
                "the Rust host's checkout fixture, pinned by its web and /api tests")
    ].freeze
  end
end
