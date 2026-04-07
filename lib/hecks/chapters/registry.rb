# Hecks::Chapters — Chapter Registration
#
# Registers all available chapters with ChapterLoader. Each entry
# declares what to require and how to wire the chapter into the
# framework. Chapters are loaded selectively via Hecks.chapters.
#
#   Hecks.chapters :bluebook, :runtime
#
module Hecks
  ChapterLoader.register(:bluebook,
    requires: %w[bluebook]
  ) do
    Chapters.load_chapter(
      Chapters::Bluebook,
      base_dirs: %w[
        hecks/domain hecks/domain_model hecks/dsl hecks/generators
        hecks/validation_rules hecks/event_storm hecks/features
        hecks/extensions/docs bluebook hecks_persist hecks_mongodb
      ].map { |d| File.join(__dir__, "../..", d) }
    )
  end

  ChapterLoader.register(:packaging,
    requires: %w[hecks/chapters/packaging]
  )

  ChapterLoader.register(:runtime,
    requires: %w[
      hecks/stats hecks/event_sourcing hecks/runtime/boot
      hecks/chapters/runtime hecks/deprecations
      hecks/runtime/boot_bluebook
    ]
  )

  ChapterLoader.register(:hecksagon,
    requires: %w[hecksagon]
  )

  ChapterLoader.register(:workshop,
    requires: %w[hecks/workshop]
  )

  ChapterLoader.register(:ai,
    requires: %w[hecks_ai]
  )

  ChapterLoader.register(:cli,
    requires: %w[hecks_cli/cli]
  )

  ChapterLoader.register(:extensions,
    requires: %w[]
  ) do
    begin; require "hecks/extensions"; rescue LoadError; end
  end

  ChapterLoader.register(:targets,
    requires: %w[hecks/chapters/targets]
  ) do
    begin; require "go_hecks"; rescue LoadError; end
    begin; require "node_hecks"; rescue LoadError; end
    begin; require "hecks_static"; rescue LoadError; end
  end

  ChapterLoader.register(:persist,
    requires: %w[hecks_persist]
  )

  ChapterLoader.register(:multidomain,
    requires: %w[hecks_multidomain]
  )

  ChapterLoader.register(:rails,
    requires: %w[]
  ) do
    require "active_hecks/railtie" if defined?(::Rails::Railtie)
  end

  ChapterLoader.register(:features,
    requires: %w[hecks/features]
  )
end
