# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # The sweep's record in the ledger and its primary seat: which comparison the seeds run
      # against, and the line that announces it.
      module Seat
        private

        # The reference embeds the target: `Sweep` is not scoped to its target, so two sweeps opened
        # in the same second must not collide.
        def open_sweep
          @sweep_reference = "SW-#{@target_reference}-#{Time.now.to_i}"
          @sweep = ::QualityControl::Sweep.open!(target: @target.id, reference: { value: @sweep_reference },
                                                 engineer: { value: @engineer })
          @differ = build_differ
          @feature = File.basename(@domain_path).downcase
        end

        # Includes `RustConformanceHelpers` outside RSpec; `structural_skips` collects verbs the
        # binary's manifest declares not generated.
        def build_differ
          require File.join(@root, "spec/support/rust_conformance_helpers")
          Class.new do
            include RustConformanceHelpers

            attr_reader :structural_skips

            def initialize
              @structural_skips = Set.new
            end
          end.new
        end

        # The primary seat is the first of persistence_parity, concurrency, differential, ruby_only
        # that is active, or none for a seedless-only sweep; differential degrades to ruby_only if
        # the build fails.
        def choose_seat
          @binary = nil
          return @mode = :seedless if @seeded_modes.empty?
          return @mode = :persistence_parity if @active_modes.include?(:persistence_parity)
          return @mode = :concurrency if @active_modes.include?(:concurrency)

          @binary = build_rust_binary if @active_modes.include?(:differential)
          return @mode = :differential if @binary

          degrade_to_ruby_only if @active_modes.include?(:differential)
          @mode = :ruby_only
        end

        def build_rust_binary
          @differ.build_rust_for(@feature, @rust_dir)
        rescue RustConformanceHelpers::BuildFailed => e
          @rust_build_failure = e
          nil
        end

        def degrade_to_ruby_only
          # `build_rust_for` answers nil only for an undeclared feature; a declared one that fails
          # raises, so its cargo stderr is printed here.
          reason = @rust_build_failure ? @rust_build_failure.message : "rust/Cargo.toml declares no #{@feature} feature"
          puts "note: no #{@feature} Rust binary — degrading this sweep to ruby_only. Run `hecks project_rust` for it " \
               "and re-sweep.\n#{reason}"
          @active_modes = (@active_modes - %i[differential properties_in_differential structural_skip_report]) |
                          [:ruby_only]
        end

        def mode_label
          case @mode
          when :differential then "Ruby vs compiled Rust (#{@feature})"
          when :persistence_parity then "Memory vs real PostgresEra (#{@feature}) — persistence-adapter parity"
          when :concurrency
            "real forked cross-process dispatch vs its own sequential oracle (#{@feature}) — write-lock serialization"
          when :seedless
            "no primary seat (#{@active_modes.join(",")} — audits this target's own real state, generates nothing)"
          else "Ruby-only property/exception check (no compiled Rust binary for #{@feature})"
          end
        end

        def announce_sweep
          if @mode == :seedless
            puts "sweeping #{@target_reference} (#{@target_path}) — #{mode_label}, " \
                 "active modes #{@active_modes.join(",")}"
          else
            puts "sweeping #{@target_reference} (#{@target_path}) — #{mode_label}, #{@seeds} seed(s), " \
                 "#{@steps_per_sequence} steps each, adversarial fraction #{@adversarial}, role draw #{@role_draw}, " \
                 "dry-run fraction #{@dry_run}, active modes #{@active_modes.join(",")}"
          end
        end
      end
    end
  end
end
