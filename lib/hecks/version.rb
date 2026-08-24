module Hecks
  # ISOLATED, ON PURPOSE — the gemspec reads this file directly rather
  # than `require_relative "lib/hecks"` (the whole framework),
  # specifically so evaluating the gemspec never triggers ANY of this
  # gem's own dependencies (prism among them) before Bundler has even
  # resolved what to install. A real, live chicken-and-egg bug caught
  # deploying to a Ruby version that doesn't bundle prism for free
  # (AWS Lambda's ruby3.2): the gemspec's own `require_relative
  # "lib/hecks"` pulled in adapters/driven/prism.rb's
  # unconditional `require "prism"`, which failed before Bundler ever
  # read what the gemspec itself declared as a dependency — declaring
  # it there, or even in the consuming Gemfile, never closed the gap,
  # because gemspec evaluation happens before anything Bundler
  # resolves is actually loadable yet.
  VERSION = "2026.07.25.1"
end
