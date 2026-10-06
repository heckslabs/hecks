# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # Everything a single-target sweep settles before the first seed: which target, which modes it
      # resolves, the claim on it, and how deep the sweep goes.
      module TargetSetup
        private

        # Existence-checked: a held or shelved target is invisible to `Rotation`, and
        # re-`Identify`ing an existing id is refused.
        def seed_default_targets!
          existing = query("Target.All").map { |row| row[:reference][:value] }
          DEFAULT_TARGETS.each do |reference, path|
            next if existing.include?(reference)

            ::QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
          end
        end

        # The only pick with no name given, where `RotationPriority.pick`'s yield weighting matters
        # (`--all` sweeps every row regardless of order).
        def pick_target_row
          return named_target_row if @target_ref

          Hecks::Fuzzing::RotationPriority.pick(waiting_rotation, now: Time.now.to_i)
        end

        def named_target_row
          row = query("Target.All").find { |r| r[:reference][:value] == @target_ref }
          return row if row

          known = query("Target.All").map { |r| r[:reference][:value] }
          abort "no such target: #{@target_ref.inspect} — known targets: #{known.inspect}"
        end

        def waiting_rotation
          rotation = query("Target.Rotation")
          if rotation.empty?
            seed_default_targets!
            rotation = query("Target.Rotation")
          end
          return rotation unless rotation.empty?

          abort "the rotation is empty even after seeding pizzas/banking — nothing waiting to sweep " \
                "(every known target is currently held or shelved)"
        end

        def select_target
          row = pick_target_row
          @target_reference = row[:reference][:value]
          @target_path = row[:path][:value]
          @domain_path = resolve_target_path(@target_path)
          return if File.directory?(@domain_path)

          abort "target #{@target_reference.inspect} names a path that does not exist on disk: #{@domain_path}"
        end

        # Before the claim: an ineligible target is an operational error (exit 1), never a finding,
        # and must not leave the target held. Deferred modes run only when the whole ask is
        # deferred; mixed with others they wait for `--all`'s later wave.
        def resolve_target_modes
          @capabilities = Hecks::Fuzzing::TargetCapabilities.infer(@domain_path, rust_dir: @rust_dir)
          resolved = Hecks::Fuzzing::TargetCapabilities.resolve(@enabled_modes, @capabilities)
          trace("capabilities+resolve")
          @deferred_modes = deferred_modes_for(resolved)
          @active_modes = resolved - @deferred_modes
          refuse_unqualified_parity
          refuse_modeless_target
          @seeded_modes = @active_modes - SEEDLESS_MODES
        end

        def deferred_modes_for(resolved)
          deferred = Hecks::Fuzzing::TargetCapabilities::DEFERRED_MODES
          explicit_all_deferred = @explicit_modes && !@explicit_modes.empty? && (@explicit_modes - deferred).empty?
          explicit_all_deferred ? [] : resolved & deferred
        end

        def refuse_unqualified_parity
          return unless @persistence_parity_mode && !@active_modes.include?(:persistence_parity)

          abort "target #{@target_reference.inspect} (#{@target_path}) declares no persisted_by(\"PostgresEra\") " \
                "binding in its own .hecksagon (capabilities: #{@capabilities.join(",")}) — " \
                "--persistence-parity has nothing to compare Memory against for this domain. " \
                "examples/directory is the known example that qualifies."
        end

        # `era_boundary` is seedless and meaningful with no primary seat; `concurrency` is a seat,
        # so it counts here too.
        def refuse_modeless_target
          return if @active_modes.intersect?(%i[differential ruby_only persistence_parity concurrency era_boundary])

          abort "target #{@target_reference.inspect} (#{@target_path}) resolves no comparison mode at all — " \
                "enabled #{@enabled_modes.join(",")}, capabilities #{@capabilities.join(",")} " \
                "(deferred: #{@deferred_modes.join(",")}). Nothing here can be swept without at least one of " \
                "differential/ruby_only/persistence_parity/concurrency/era_boundary."
        end

        def claim_target
          @target = ::QualityControl::Target.find(@target_reference)
          abort "target #{@target_reference.inspect} vanished between being queried and being claimed" unless @target

          begin
            @target = @target.claim!(held_by: { value: @engineer }, now: { value: Time.now.to_i })
          rescue Hecks::Runtime::GivenNotMet => e
            abort "target #{@target_reference.inspect} is already held and its claim has not gone stale yet " \
                  "(#{e.message})"
          end
          trace("claim")
        end
      end
    end
  end
end
