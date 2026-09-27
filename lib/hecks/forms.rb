# The forms surface: `expose`, the HTML renderers and the Rack app serving them.
# Not loaded by `require "hecks"`, so `rack` stays a lazy dependency.
require "hecks"
require_relative "forms/app"

module Hecks
  # Per-app `expose` configuration, looked up by the Rack app at request time.
  module Forms
    # The chapters one app exposes. Plain module state, outside `syntax.bluebook` and
    # the registry; one `expose` switches on a whole chapter, not a single command or query.
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
