# = HecksWatchers
#
# File watchers for Hecks development. Each watcher checks staged .rb files
# for a specific quality concern: file size, cross-component isolation,
# autoload registration, and spec coverage.
#
# == Usage
#
#   require "hecks_watchers"
#
#   # Run a single watcher
#   watcher = HecksWatchers::FileSize.new(project_root: Dir.pwd)
#   watcher.call
#
#   # Run all watchers in a polling loop
#   runner = HecksWatchers::Runner.new(project_root: Dir.pwd)
#   runner.start
#
# Load watcher implementation files from the Watchers chapter definition.
require_relative "hecks/chapters/watchers"
Hecks::Chapters.load_chapter(
  Hecks::Chapters::Watchers,
  base_dir: File.expand_path("hecks_watchers", __dir__)
)
