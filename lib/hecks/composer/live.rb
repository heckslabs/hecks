require "fileutils"
require "hecks"
require_relative "parse"
require_relative "plain"
require_relative "workspace"

module Hecks
  module Composer
    # A workspace domain booted once and kept, so the Console and Records panels can dispatch
    # commands against it and read back what it holds. It sits on the driving side of the
    # hecksagon: the editor drives the domain, the domain keeps its records in memory, and the
    # staged copy of the files lives until `close`.
    class Live
      # @return [String] the chapter the workspace booted
      attr_reader :chapter_name

      # Stages the workspace and boots it in memory.
      #
      # @param dir [String] the workspace directory
      # @param buffers [Hash{String => String}] unsaved text by path relative to `dir`
      # @return [Live] a booted workspace
      # @raise [StandardError, ScriptError] whatever the parse or the boot refused with (a
      #   bluebook that is not valid Ruby raises a SyntaxError); the stage is removed
      def self.open(dir:, buffers: {})
        stage = Workspace.materialize(dir: dir, buffers: buffers)
        begin
          runtime = Hecks.boot(stage, install_driving: false, environment: "memory")
          new(stage: stage, runtime: runtime, chapter_name: Parse.bluebooks(stage).keys.first)
        rescue StandardError, ScriptError
          FileUtils.rm_rf(stage)
          raise
        end
      end

      # @param stage [String] the staged directory this domain booted from
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param chapter_name [String] the chapter's name
      def initialize(stage:, runtime:, chapter_name:)
        @stage = stage
        @runtime = runtime
        @chapter_name = chapter_name
      end

      # The aggregate commands the chapter declares, each with a starter value for every argument.
      #
      # @return [Array<Hash>] per command: `verb`, `aggregate`, `command`, `goal`, `creates`,
      #   `args` (`{name:, type:, optional:}` each) and `template` (argument name to starter value)
      def commands
        aggregates.flat_map do |aggregate|
          aggregate.commands.map { |command| describe(aggregate, command) }
        end
      end

      # Runs one command against the booted domain.
      #
      # @param verb [String] the dispatcher's form, such as "Ledger::Account.Credit"
      # @param to [String, nil] the identity of the record the command addresses
      # @param with [Hash] the command's facts by argument name; keys may be strings
      # @return [Hash] `{ok: true, events:, instance:}` with the event names and the plain row, or
      #   `{ok: false, kind:, error:}` with the refusal's class name and first message line
      def dispatch(verb:, to: nil, with: {})
        accepted(@runtime.dispatch(verb, to: to, with: symbolize(with)))
      rescue StandardError => e
        refused(e)
      end

      # @return [Hash{String => Array<Hash>}] each aggregate's name to its records as plain rows
      def records
        aggregates.to_h do |aggregate|
          rows = @runtime.registry.repository(@chapter_name, aggregate).all
          [aggregate.hecks_name, Plain.call(rows.to_a)]
        end
      end

      # @param limit [Integer] how many of the latest events to return
      # @return [Array<Hash>] the last `limit` events, oldest first, as plain Hashes with `name`,
      #   `aggregate`, `id`, `payload` and `occurred_at`
      def history(limit = 200)
        latest = @runtime.events.to_a.last(limit)
        latest.map { |event| Plain.call(event.to_h) }
      end

      # Removes the staged copy of the workspace. Calling it again does nothing.
      #
      # @return [void]
      def close
        FileUtils.rm_rf(@stage)
      end

      # @api private
      def aggregates = @runtime.registry.bluebook(@chapter_name).aggregates

      # @api private
      def accepted(result)
        { ok: true, events: result.events.map { |event| event.to_h[:name] },
          instance: Plain.call(result.instance) }
      end

      # @api private
      def refused(error)
        { ok: false, kind: short_class_name(error), error: headline(error.message) }
      end

      # @api private
      def short_class_name(error)
        name = error.class.name.to_s
        name.split("::").last
      end

      # The first line of a message, without its line ending.
      # @api private
      def headline(message)
        line = message.lines.first
        line.to_s.chomp
      end

      # @api private
      def describe(aggregate, command)
        args = arguments(command)
        { verb: "#{@chapter_name}::#{aggregate.hecks_name}.#{command.hecks_name}",
          aggregate: aggregate.hecks_name, command: command.hecks_name, goal: command.goal.to_s,
          creates: command.references.nil?, args: args, template: template(aggregate, args) }
      end

      # @api private
      def template(aggregate, args)
        args.to_h { |arg| [arg[:name], starter(aggregate, arg[:type])] }
      end

      # @api private
      def arguments(command)
        command.attributes.map do |attr|
          { name: attr.name.to_s, type: attr.type.to_s, optional: attr.optional? }
        end
      end

      # A value object of the aggregate gets a Hash of its attributes' defaults; any other type, "".
      # @api private
      def starter(aggregate, type)
        shape = aggregate.value_object(type)
        return "" unless shape

        shape.attributes.to_h { |attr| [attr.name.to_s, default_for(attr)] }
      end

      # @api private
      def default_for(attr)
        return attr.default unless attr.default.nil?

        attr.type.to_s == "Integer" ? 0 : ""
      end

      # @api private
      def symbolize(item)
        case item
        when Hash then item.to_h { |key, inner| [key.to_sym, symbolize(inner)] }
        when Array then item.map { |inner| symbolize(inner) }
        else item
        end
      end
    end
  end
end
