# frozen_string_literal: true

# Local-only: `bundle exec guard` reruns the matching spec on save. Not
# wired into CI or the pre-push hook — the real gate stays
# `bundle exec rspec` / `bundle exec parallel_rspec spec`.

# Raises a system notification on each run's result (Terminal Notifier
# on macOS, libnotify on Linux). Notiffany tries each in turn and
# skips whichever gem isn't installed on the current machine.
notification :terminal_notifier
notification :libnotify

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
