require "spec_helper"
require "hecks/fuzzing"
require "tempfile"

# `Hecks::Fuzzing::QaSettings`, THE ADAPTER FOR `qa/settings.yml` — proven
# here against tiny fixture files of its own, the same discipline
# `spec/rotation_priority_spec.rb`/`spec/sweep_depth_spec.rb` keep for
# their sibling modules: no ledger boot, nothing borrowed from the real
# dial file, so a change to this class's own contract fails here first.
# The REAL file (`qa/settings.yml`) loading cleanly, with the SAME values
# the old Ruby literals carried, is proven by `spec/quality_control_spec.rb`
# booting the real chapter — this file is only about the adapter's own
# refuse-or-accept behaviour.
RSpec.describe Hecks::Fuzzing::QaSettings do
  # A MINIMAL, COMPLETE FIXTURE — every key `EXPECTED_TYPES` names, small
  # values chosen for clarity rather than realism (the real numbers are
  # `qa/settings.yml`'s job to carry, not this file's).
  def valid_yaml
    <<~YAML
      cadence_seconds: 0
      pr_cap_per_day: 3
      widening_tiers:
        - { upto: 4, seeds: 10, steps: 25 }
        - { upto: .inf, seeds: 50, steps: 100 }
      sweep_max_parallel: 4
      liveness_fallback_seconds: 1500
      draft_only: false
      auto_merge: true
      branch_prefix: "qa/"
      adversarial_fraction: 0.3
      guided_generation: true
      corpus_splice_probability: 0.0
      favor_rare_verbs: 3
      self_consistency_checks: true
      shrink_budget: 200
      yield_weight_seconds: 1800
      yield_decay_percent: 50
      rotation_stale_floor_seconds: 21600
      persistence_parity_seed_cap: 5
      concurrency_seed_cap: 3
      adapter_parity_pairs:
        persistence_parity:
          left: memory
          right: postgres_era
        adapter_parity_sqlite:
          left: memory
          right: sqlite
      modes:
        differential: true
        ruby_only: true
      role_draw_probability: 0.25
      dry_run_fraction: 0.10
      generated_domains_per_tick: 2
      generated_domains_rust: true
      generated_domain_seeds: 5
      structural_refusal_boundary:
        - cursor
        - consistency
    YAML
  end

  def with_settings_file(contents)
    file = Tempfile.new(["qa_settings", ".yml"])
    file.write(contents)
    file.close
    yield file.path
  ensure
    file&.unlink
  end

  describe ".load" do
    it "loads a valid file and exposes every dial by its own typed accessor" do
      with_settings_file(valid_yaml) do |path|
        settings = described_class.load(path)

        expect(settings.cadence_seconds).to eq(0)
        expect(settings.pr_cap_per_day).to eq(3)
        expect(settings.sweep_max_parallel).to eq(4)
        expect(settings.branch_prefix).to eq("qa/")
        expect(settings.draft_only).to be(false)
        expect(settings.auto_merge).to be(true)
        expect(settings.adversarial_fraction).to eq(0.3)
      end
    end

    it "parses the widening tiers as an array of symbol-keyed hashes, INFINITY intact" do
      with_settings_file(valid_yaml) do |path|
        tiers = described_class.load(path).widening_tiers
        expect(tiers).to eq([{ upto: 4, seeds: 10, steps: 25 }, { upto: Float::INFINITY, seeds: 50, steps: 100 }])
      end
    end

    it "symbolizes modes' keys, matching what QualityControlDials::MODES has always been" do
      with_settings_file(valid_yaml) do |path|
        expect(described_class.load(path).modes).to eq(differential: true, ruby_only: true)
      end
    end

    it "symbolizes adapter_parity_pairs' left/right VALUES, not just its keys — IsolatedBoot case-matches by Symbol" do
      with_settings_file(valid_yaml) do |path|
        pairs = described_class.load(path).adapter_parity_pairs
        expect(pairs).to eq(
          persistence_parity:    { left: :memory, right: :postgres_era },
          adapter_parity_sqlite: { left: :memory, right: :sqlite }
        )
      end
    end

    it "returns a frozen instance with frozen collection values, so nothing mutates a loaded dial by accident" do
      with_settings_file(valid_yaml) do |path|
        settings = described_class.load(path)
        expect(settings).to be_frozen
        expect(settings.widening_tiers).to be_frozen
        expect(settings.modes).to be_frozen
        expect(settings.structural_refusal_boundary).to be_frozen
      end
    end

    it "refuses a path that does not exist" do
      expect { described_class.load("/tmp/does-not-exist-#{SecureRandom.hex(8)}.yml") }
        .to raise_error(ArgumentError, /not found/)
    end

    it "refuses a file that is not valid YAML" do
      with_settings_file("cadence_seconds: [unterminated") do |path|
        expect { described_class.load(path) }.to raise_error(ArgumentError, /not valid YAML/)
      end
    end

    it "refuses a YAML file that is not a mapping at the top level" do
      with_settings_file("- 1\n- 2\n") do |path|
        expect { described_class.load(path) }.to raise_error(ArgumentError, /must be a YAML mapping/)
      end
    end

    it "refuses a file missing a required key, naming it" do
      with_settings_file(valid_yaml.sub("cadence_seconds: 0\n", "")) do |path|
        expect { described_class.load(path) }.to raise_error(ArgumentError, /missing.*cadence_seconds/)
      end
    end

    it "refuses a file naming an extra, unrecognised key rather than silently ignoring it" do
      with_settings_file("#{valid_yaml}nonsense_dial: 1\n") do |path|
        expect { described_class.load(path) }.to raise_error(ArgumentError, /unknown key.*nonsense_dial/)
      end
    end

    it "refuses a dial of the wrong type, naming what it got" do
      with_settings_file(valid_yaml.sub("sweep_max_parallel: 4", "sweep_max_parallel: \"four\"")) do |path|
        expect { described_class.load(path) }
          .to raise_error(ArgumentError, /sweep_max_parallel must be a Integer.*got String/)
      end
    end

    it "refuses a boolean dial given neither true nor false" do
      with_settings_file(valid_yaml.sub("draft_only: false", "draft_only: \"nope\"")) do |path|
        expect { described_class.load(path) }.to raise_error(ArgumentError, /draft_only/)
      end
    end

    it "refuses an adapter_parity_pairs entry missing left or right" do
      broken = valid_yaml.sub(/^\s*right: postgres_era\n/, "")
      with_settings_file(broken) do |path|
        expect { described_class.load(path) }.to raise_error(ArgumentError, /adapter_parity_pairs/)
      end
    end
  end
end
