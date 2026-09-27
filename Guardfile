# frozen_string_literal: true

# Local-only: `bundle exec guard` reruns the matching spec on save. Not
# wired into CI or the pre-push hook — the real gate stays
# `bundle exec rspec` / `bundle exec parallel_rspec spec`.

# Raises a system notification on each run's result (Terminal Notifier
# on macOS, libnotify on Linux). Notiffany tries each in turn and
# skips whichever gem isn't installed on the current machine.
notification :terminal_notifier
notification :libnotify

# Builds rust/ whenever a source file or manifest under it changes, so
# a conformance spec's `native`/`build` mode (bin/rust_conformance)
# never compares Ruby against a Rust binary that predates the edit
# that was just saved.
module ::Guard
  # A Guard plugin that shells out to `cargo build` for its matched
  # watchers, defined inline here rather than pulled in as a gem since
  # it is this one command.
  class CargoBuild < Plugin
    # Rebuilds rust/ so the next conformance spec run has a fresh binary.
    #
    # @param _paths [Array<String>] the changed paths that matched this plugin's watchers
    # @return [void]
    def run_on_changes(_paths)
      system("cargo", "build", chdir: "rust") or throw :task_has_failed
    end
  end
end

guard :cargo_build do
  watch(%r{^rust/(?!target/).*\.rs$})
  watch(%r{^rust/Cargo\.(toml|lock)$})
end

guard :rspec, cmd: "bundle exec rspec" do
  require "guard/rspec/dsl"
  dsl = Guard::RSpec::Dsl.new(self)

  rspec = dsl.rspec
  watch(rspec.spec_helper) { rspec.spec_dir }
  watch(rspec.spec_support) { rspec.spec_dir }
  watch(rspec.spec_files)

  ruby = dsl.ruby
  dsl.watch_spec_files_for(ruby.lib_files)
end
