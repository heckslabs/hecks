# The forms surface: `expose` (the DSL a `command_form.bluebook`/
# `query_form.bluebook` will eventually become — see docs/
# command-form-and-query-form-bluebook.md), the IR->HTML renderers, and
# the Rack app that content-negotiates between them and a plain JSON
# reading of the same dispatch. Not required by `require "hecks"`
# itself — a project that never boots this file never pays for `rack`,
# the same lazy-dependency discipline the Gemfile's own comment already
# holds `pg`/`oauth2`/`aws-sdk-lambda` to.
#
# See docs/command-form-and-query-form-bluebook.md for the design this
# implements and what it deliberately leaves for later.
require "hecks"
require_relative "forms/app"

module Hecks
  # Per-chapter `expose` configuration, keyed by chapter name and looked up
  # by the Rack app at request time (`.config`) to decide which chapters'
  # forms are switched on at all — see the file header above for what
  # `expose` deliberately does and does not cover.
  module Forms
    # `expose`'s own declaration — "which chapters does this app expose" —
    # kept outside the `Hecks.*` collector convention (`Hecks.bluebook`,
    # `Hecks.hecksagon`, ...) and outside `Runtime::Registry` entirely, on
    # purpose: a real language word goes through `syntax.bluebook` and
    # `MetaValidator` (see docs/implemented/guides/extending-hecks.md, "a new word is a
    # declared row before it is a line of Ruby") and is judged by
    # spec/syntax_conformance_spec.rb + spec/dsl_coverage_spec.rb — gates
    # this construct has not earned yet. An ordinary Ruby DSL, one level of
    # module state, no different in kind from a project's own initializer —
    # see docs/command-form-and-query-form-bluebook.md, "why this isn't
    # syntax.bluebook yet".
    #
    # One `expose` grants a whole chapter, not a command or a query
    # individually — the future `command_form.bluebook`/`query_form.bluebook`
    # words are per-declaration (one command, one query, its own form/view,
    # possibly its own overrides), which `expose` doesn't do today and was
    # never trying to; it's the coarse "turn this chapter's forms on at
    # all" switch those finer words will eventually sit inside.
    class Config
      attr_reader :name, :exposes

      # @param name [String, Symbol] the app name this configuration is registered under;
      #   stored as a String
      def initialize(name)
        @name    = name.to_s
        @exposes = []
      end

      # Switches on the forms of one whole chapter for this app; called inside the
      # `Forms.configure` block.
      #
      # @param chapter_name [String, Symbol] name of the chapter (domain) to expose, such as
      #   `"Banking"`; stored as a String
      # @return [Array<String>] every chapter name exposed so far, in declaration order
      def expose(chapter_name) = @exposes << chapter_name.to_s
    end

    # Declares an app and the chapters it exposes, replacing any earlier configuration
    # registered under the same name.
    #
    # @param name [String, Symbol] the app name `App.for` later looks the configuration up by
    # @yield evaluated with `instance_eval` against the new `Forms::Config`, so a bare
    #   `expose "Banking"` inside the block reaches `Config#expose`; optional
    # @return [Forms::Config] the configuration just registered
    def self.configure(name, &block)
      config = Config.new(name)
      config.instance_eval(&block) if block
      (@configs ||= {})[config.name] = config
    end

    # Looks up the configuration an earlier `Forms.configure` registered.
    #
    # @param name [String, Symbol] the app name given to `Forms.configure`
    # @return [Forms::Config, nil] the app's configuration, or nil when no app of that name
    #   has been configured
    def self.config(name) = (@configs || {})[name.to_s]
  end
end
