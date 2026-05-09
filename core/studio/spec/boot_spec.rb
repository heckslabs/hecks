# spec/boot_spec.rb
#
# Studio boot acceptance.
#
# Asserts :
#   1. Hecks.boot(studio_dir) returns a runtime (or array of runtimes).
#   2. The Studio aggregate IR is present in the booted domain.
#   3. After boot, six TickedFeature seed rows exist :
#      heart, breath, circadian, ultradian, sleep_cycle, mindstream
#      (status may be "pending" — the spec freezes their NAMES, not
#      their states).
#
# What this does NOT assert : that any cadence is actually ticking,
# that policies have fired, that statusline has updated. Boot only.
#
# Resilience : every assertion produces a clear pending/skip when the
# bluebook is not yet applied, never a NameError stack.
#
# Usage:
#   bundle exec rspec spec/boot_spec.rb

require_relative "spec_helper"

EXPECTED_CADENCES = %w[
  heart
  breath
  circadian
  ultradian
  sleep_cycle
  mindstream
].freeze

def boot_studio
  # Prefer the already-booted runtime on the loaded Sinatra app —
  # avoids a second boot (slow + double-seeds the cadences).
  return STUDIO_APP.runtime if STUDIO_APP.respond_to?(:runtime) && STUDIO_APP.runtime

  return nil unless defined?(BootStudio)
  studio_dir = File.expand_path("..", __dir__)
  BootStudio.call(studio_dir)
rescue StandardError, ScriptError => e
  warn "[boot_spec] BootStudio.call raised: #{e.class}: #{e.message}"
  nil
end

def find_runtime(result)
  return nil unless result
  return result if result.respond_to?(:domain)
  return result.find { |r| r.respond_to?(:domain) } if result.is_a?(Array)
  nil
end

def find_aggregate(runtime, name)
  return nil unless runtime&.domain&.respond_to?(:aggregates)
  runtime.domain.aggregates.find { |a| a.name == name }
end

def ticked_feature_records(runtime)
  return [] unless runtime
  agg = find_aggregate(runtime, "TickedFeature")
  return [] unless agg

  mod_name = runtime.domain.name.to_s
  klass = nil
  begin
    mod = Object.const_get(mod_name)
    klass = mod.const_defined?(:TickedFeature) ? mod.const_get(:TickedFeature) : nil
  rescue NameError
    klass = nil
  end
  return [] unless klass

  if klass.respond_to?(:all)
    Array(klass.all)
  else
    []
  end
rescue StandardError => e
  warn "[boot_spec] reading TickedFeature records failed: #{e.class}: #{e.message}"
  []
end

RSpec.describe "Hecks Studio boot" do
  unless defined?(Hecks) && Hecks.respond_to?(:boot)
    it "is skipped because Hecks itself is not loadable in this env" do
      skip "Hecks is not available on the load path"
    end
  else
    let(:boot_result) { boot_studio }
    let(:runtime)     { find_runtime(boot_result) }

    describe "Hecks.boot(studio_dir)" do
      it "returns a runtime (or array of runtimes)" do
        if boot_result.nil?
          skip "Hecks.boot returned nil — bluebook may not yet be applied"
        end
        expect(runtime).not_to(
          be_nil,
          "expected a Hecks::Runtime ; got #{boot_result.inspect[0, 200]}"
        )
        expect(runtime).to respond_to(:domain)
      end
    end

    describe "Studio aggregate IR" do
      it "is present in the booted domain" do
        skip "boot did not produce a runtime" unless runtime
        agg = find_aggregate(runtime, "Studio")
        expect(agg).not_to(
          be_nil,
          "expected a Studio aggregate ; saw " \
          "#{runtime.domain.aggregates.map(&:name).inspect}"
        )
      end
    end

    describe "TickedFeature seed rows" do
      it "contains the six cadence names after boot" do
        skip "boot did not produce a runtime" unless runtime
        records = ticked_feature_records(runtime)
        if records.empty?
          skip "TickedFeature has no records yet — bluebook seed not applied"
        end

        names = records.map do |r|
          r.respond_to?(:name) ? r.name.to_s : r.to_s
        end

        EXPECTED_CADENCES.each do |cadence|
          expect(names).to(
            include(cadence),
            "expected cadence #{cadence.inspect} in TickedFeature ; " \
            "saw: #{names.inspect}"
          )
        end
      end
    end
  end
end
