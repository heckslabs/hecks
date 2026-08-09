# The presentation surface: `presentation.bluebook`'s `expose` word, the
# IR->HTML renderers, and the Rack app that content-negotiates between
# them and a plain JSON reading of the same dispatch. NOT required by
# `require "hecksagain"` itself — a project that never boots this file
# never pays for `rack`, the same lazy-dependency discipline the Gemfile's
# own comment already holds `pg`/`oauth2`/`aws-sdk-lambda` to.
#
# See docs/presentation-bluebook.md for the design this implements and
# what it deliberately leaves for later.
require "hecksagain"
require_relative "presentation/app"

module Hecksagain
  module Presentation
    # `presentation.bluebook`'s own declaration — "which chapters does
    # this presentation expose" — kept OUTSIDE the `Hecks.*` collector
    # convention (`Hecks.bluebook`, `Hecks.hecksagon`, ...) and outside
    # `Runtime::Registry` entirely, on purpose: a real language word goes
    # through `syntax.bluebook` and `MetaValidator` (see docs/guides/
    # extending-hecks.md, "a new word is a declared row before it is a
    # line of Ruby") and is judged by spec/syntax_conformance_spec.rb +
    # spec/dsl_coverage_spec.rb — gates this construct has not earned yet.
    # An ordinary Ruby DSL, one level of module state, no different in
    # kind from a project's own initializer — see docs/presentation-bluebook.md,
    # "why this isn't syntax.bluebook yet".
    class Config
      attr_reader :name, :exposes

      def initialize(name)
        @name    = name.to_s
        @exposes = []
      end

      def expose(chapter_name) = @exposes << chapter_name.to_s
    end

    def self.configure(name, &block)
      config = Config.new(name)
      config.instance_eval(&block) if block
      (@configs ||= {})[config.name] = config
    end

    def self.config(name) = (@configs || {})[name.to_s]
  end
end
