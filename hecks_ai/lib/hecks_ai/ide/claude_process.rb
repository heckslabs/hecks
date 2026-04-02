# Hecks::AI::IDE::ClaudeProcess
#
# Runs Claude Code in --print mode with stream-json output. Each
# prompt spawns a process; session ID is captured for resumption.
#
#   proc = ClaudeProcess.new(project_dir: ".") { |json| puts json }
#   proc.send_prompt("say hi")
#   proc.interrupt!
#
require "open3"
require "json"

module Hecks
  module AI
    module IDE
      class ClaudeProcess
        def initialize(project_dir: Dir.pwd, &on_event)
          @project_dir = project_dir
          @on_event = on_event
          @session_id = nil
          @current_pid = nil
          @mutex = Mutex.new
        end

        def send_prompt(prompt)
          Thread.new { run_once(prompt) }
        end

        def interrupt!
          @mutex.synchronize do
            Process.kill(:INT, @current_pid) rescue nil if @current_pid
            @current_pid = nil
          end
        end

        def stop
          interrupt!
        end

        private

        def run_once(prompt)
          cmd = [
            "claude", "--print",
            "--output-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions"
          ]
          cmd += ["--resume", @session_id] if @session_id

          Open3.popen3({ "TERM" => "dumb" }, *cmd, prompt, chdir: @project_dir) do |_in, out, err, thr|
            @mutex.synchronize { @current_pid = thr.pid }
            out.each_line do |line|
              line = line.strip
              next if line.empty?
              capture_session_id(line)
              @on_event.call(line)
            end
            err.read
            thr.value
          end
        rescue => e
          @on_event.call(JSON.generate(type: "error", message: e.message))
        ensure
          @mutex.synchronize { @current_pid = nil }
          @on_event.call(JSON.generate(type: "result", subtype: "done"))
        end

        def capture_session_id(line)
          return if @session_id
          data = JSON.parse(line) rescue nil
          @session_id = data["session_id"] if data&.key?("session_id")
        end
      end
    end
  end
end
