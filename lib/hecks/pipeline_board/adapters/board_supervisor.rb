# frozen_string_literal: true

require "json"
require "net/http"
require "tmpdir"
require_relative "probe"
require_relative "rules"
require_relative "deadline"

module Hecks
  module Adapters
    # The `Supervisor` port's adapter: sees a serving board from outside its process, and
    # restarts it. It probes `GET /`, the page that wedged, then `GET /api/state` for the board's
    # own `stale` flag, and it decides nothing: the bluebook's `RestartWhenBoardUnresponsive`
    # policy says that a board that does not answer is restarted. Both limits are `Setting` rows.
    class BoardSupervisor
      HOST = "127.0.0.1"
      LOG = File.join(Dir.tmpdir, "hecks-pipeline-board-restart.log")

      # @param host [Hash] stand-ins for the outside: `get:` (takes a path and the port, answers
      #   `[status, body]`), `listeners:` (takes the port, answers the pids listening on it),
      #   `signal:` (takes a signal name and a pid), `alive:` (takes a pid), `start:` (takes the
      #   port and starts the board detached), `pause:` (takes seconds) and `limits:` (answers
      #   `answer:` and `grace:` seconds)
      def initialize(**host)
        @host = host_defaults.merge(host)
      end

      # @param held [Hash] the ask's arguments: `port`
      # @return [Hash{Symbol => Object}] `answered:` the status of `GET /`
      # @raise [PipelineBoard::Unavailable] when the board does not answer in time, answers a
      #   status other than 200, or reports its own state as stale
      def probe(**held)
        port = port_of(held)
        status, = answering(port, "/")
        raise PipelineBoard::Unavailable, "the board answered #{status} to GET /" unless status == 200

        stale = JSON.parse(answering(port, "/api/state").last)["stale"]
        raise PipelineBoard::Unavailable, "the board's state is stale" if stale

        { answered: status }
      end

      # Stops whatever listens on the port (asked to stop, then killed after the grace) and starts
      # the board again, detached, as the launcher's `Board.serve!`.
      # @param held [Hash] the ask's arguments: `port`
      # @return [Hash{Symbol => Array<Integer>}] `stopped:` the pids that were listening
      def restart(**held)
        port = port_of(held)
        pids = @host[:listeners].call(port)
        stop(pids)
        @host[:start].call(port)
        { stopped: pids }
      end

      private

      def host_defaults
        { get: method(:fetch), listeners: method(:listening), alive: method(:running?), start: method(:spawn_board),
          signal: ->(name, pid) { Process.kill(name, pid) }, pause: ->(seconds) { sleep(seconds) },
          limits: method(:declared) }
      end

      def port_of(held) = (held[:port].is_a?(Hash) ? held[:port][:value] : held[:port]).to_i

      def declared = { answer: Rules.setting("board_answer_seconds"), grace: Rules.setting("board_stop_grace_seconds") }

      # The whole request has the limit, not each read of it.
      def answering(port, path)
        PipelineBoard::Deadline.run(@host[:limits].call[:answer], "GET #{path}") { @host[:get].call(path, port) }
      rescue PipelineBoard::Deadline::Overdue, SystemCallError, IOError => e
        raise PipelineBoard::Unavailable, "the board did not answer GET #{path}: #{e.message}"
      end

      def fetch(path, port)
        reply = Net::HTTP.get_response(URI("http://#{HOST}:#{port}#{path}"))
        [reply.code.to_i, reply.body.to_s]
      end

      def stop(pids)
        pids.each { |pid| signal("TERM", pid) }
        @host[:pause].call(@host[:limits].call[:grace]) if pids.any? { |pid| @host[:alive].call(pid) }
        pids.each { |pid| signal("KILL", pid) if @host[:alive].call(pid) }
      end

      def signal(name, pid)
        @host[:signal].call(name, pid)
      rescue Errno::ESRCH
        nil
      end

      def running?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      # Not guarded: a loaded machine is when a wedged board most needs to be restarted.
      def listening(port)
        PipelineBoard::Probe.run("lsof", "-ti", "tcp:#{port}", "-sTCP:LISTEN", guarded: false).split.map(&:to_i)
      rescue PipelineBoard::Unavailable
        []
      end

      # Detached, in its own process group: it outlives this process and the probe's reaping.
      def spawn_board(port)
        root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", Dir.pwd)
        pid = Process.spawn(File.join(root, "exe", "hecks"), "Board.serve!", "port=#{port}", "--wait",
                            chdir: root, pgroup: true, in: File::NULL, out: [LOG, "a"], err: [:child, :out])
        Process.detach(pid)
      end
    end
  end
end
