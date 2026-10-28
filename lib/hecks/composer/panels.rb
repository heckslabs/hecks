require_relative "../text"
require "digest"
require "json"
require_relative "live"
require_relative "toolbox"
require_relative "behavior_run"
require_relative "board_edit"
require_relative "jobs"

module Hecks
  module Composer
    # What the editor's lower panels ask of the server, on the hecksagon side: the Console and
    # Records panels (a booted copy of the workspace), the Behaviors panel, Hecks's own commands for
    # the palette and Eras, and the one background job the Fuzz panel polls. Every method takes the
    # request's JSON body as a Hash and answers a Hash, so the router stays a table.
    #
    # The booted copy is kept between requests and rebuilt when the files or unsaved text change, so
    # the records a Console command made survive until the text does.
    class Panels
      # Replaced, in a command's argument values, by the workspace directory.
      WORKSPACE_TOKEN = "$WORKSPACE".freeze

      # @param workspace [String] the domain directory the editor opens
      # @param session [Session] the editor's in-memory draft bookkeeping, which keeps the timeline
      def initialize(workspace:, session:)
        @workspace = workspace
        @session = session
        @lock = Mutex.new
        at_exit { close }
      end

      # Removes the booted copy of the workspace, if one is held.
      # @return [void]
      def close
        @live&.close
        @live = @live_key = nil
      end

      # @param body [Hash] `buffers`
      # @return [Hash] `bluebook` and `commands` (see {Live#commands}), or `error`
      def commands(body)
        with_live(body) { |live| { bluebook: live.declaration_name, commands: live.commands } }
      end

      # @param body [Hash] `buffers`, `verb`, `to` and `with`
      # @return [Hash] see {Live#dispatch}, or `error` when the text does not boot
      def dispatch(body)
        with_live(body) { |live| live.dispatch(verb: body.fetch("verb"), to: body["to"], with: body.fetch("with", {})) }
      end

      # @param body [Hash] `buffers`
      # @return [Hash] `records` by aggregate and `history` of events, or `error`
      def records(body) = with_live(body) { |live| { records: live.records, history: live.history } }

      # @param body [Hash] `buffers`
      # @return [Hash] see {BehaviorRun.call}
      def behaviors(body) = BehaviorRun.call(dir: @workspace, buffers: body.fetch("buffers", {}))

      # Carries out one board action on the workspace as it is on screen.
      #
      # @param body [Hash] `buffers`, `op` (see {BoardEdit::OPERATIONS}) and `args`
      # @return [Hash] the patched file as `path`, `text` and `line`, or `error` when the action
      #   is refused
      def board_edit(body)
        Workspace.stage(dir: @workspace, buffers: body.fetch("buffers", {})) do |stage|
          BoardEdit.call(stage: stage, action: body.fetch("op"), args: body.fetch("args", {}))
        end
      rescue BoardEdit::Refused => e
        { error: e.message }
      end

      # @param body [Hash] `path`
      # @return [Hash] `revisions`, newest first (see {Session#timeline})
      def timeline(body) = { revisions: @session.timeline(body.fetch("path")) }

      # @param _body [Hash] unused
      # @return [Hash] `catalog` of Hecks's commands and queries (see {Toolbox#catalog})
      def catalog(_body) = { catalog: toolbox.catalog }

      # @param body [Hash] `kind` and `verb`
      # @return [Hash] `help` text
      def help(body) = { help: toolbox.help(kind: body.fetch("kind"), verb: body.fetch("verb")) }

      # @param body [Hash] `kind`, `verb`, `args` and `confirm`
      # @return [Hash] see {Toolbox#run}
      def run(body) = toolbox.run(**request_of(body))

      # @param _body [Hash] unused
      # @return [Hash] the era queries over the workspace (see {Toolbox#eras})
      def eras(_body) = toolbox.eras(@workspace)

      # Starts the background job, unless one is running.
      #
      # @param body [Hash] `kind`, `verb`, `args` and `confirm`
      # @return [Hash] `started`, and `error` when a job was already running
      def start_job(body)
        jobs.start(**request_of(body))
        { started: true }
      rescue Jobs::Busy => e
        { started: false, error: e.message }
      end

      # @param _body [Hash] unused
      # @return [Hash] the job's state (see {Jobs#state})
      def job_state(_body) = jobs.state

      # @param _body [Hash] unused
      # @return [Hash] `cancelled`, whether a job was running
      def cancel_job(_body) = { cancelled: jobs.cancel }

      private

      def with_live(body)
        @lock.synchronize { yield live_for(body.fetch("buffers", {})) }
      rescue StandardError, ScriptError => e
        { error: Text.headline(e.message) }
      end

      def live_for(buffers)
        key = digest(buffers)
        return @live if @live && key == @live_key

        close
        @live = Live.open(dir: @workspace, buffers: buffers)
        @live_key = key
        @live
      end

      def digest(buffers)
        disk = Workspace.files(@workspace).to_h { |path| [path, File.read(File.join(@workspace, path))] }
        Digest::SHA256.hexdigest(JSON.generate([disk.sort, buffers.sort]))
      end

      def request_of(body)
        args = body.fetch("args", {}).transform_values { |value| value.to_s.gsub(WORKSPACE_TOKEN, @workspace) }
        { kind: body.fetch("kind"), verb: body.fetch("verb"), args: args, confirm: body["confirm"] }
      end

      def toolbox = @toolbox ||= Toolbox.new

      # A second toolbox, so a long job does not hold up the palette.
      def jobs = @jobs ||= Jobs.new(runner: ->(**request) { Toolbox.new.run(**request) })
    end
  end
end
