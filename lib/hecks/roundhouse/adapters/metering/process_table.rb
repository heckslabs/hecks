# frozen_string_literal: true

module Hecks
  module Adapters
    class Metering
      # The machine's processes as `ps -axo pid=,ppid=,rss=,%cpu=,command=` prints them, read as a
      # tree, so a session is metered with every process it started: its MCP servers, its shells,
      # its specs. It only parses the text it is handed.
      class ProcessTable
        # One process: its parent, its resident memory in kilobytes, its CPU percent and its
        # command line.
        Row = Struct.new(:pid, :ppid, :rss_kb, :cpu, :command, keyword_init: true)

        # What a session's tree adds up to.
        Tree = Struct.new(:memory_mb, :cpu, :processes, :mcp_servers, keyword_init: true)

        # The command lines of the two MCP servers a session in this repository starts.
        MCP = %r{hecks/adapters/driving/mcp/stdio_entry'|query_ir_mcp/stdio_entry'|serve_query_ir_mcp}

        # One `ps` line: pid, ppid, rss, %cpu, then the command with its spaces.
        LINE = /\A\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+(.*)\z/

        KB_PER_MB = 1024

        # @param text [String] the `ps` output
        def initialize(text)
          @rows = parsed(text).to_h { |row| [row.pid, row] }
          @children = @rows.values.group_by(&:ppid)
        end

        # @param pid [Integer] a process id
        # @return [Boolean] whether the process is running
        def running?(pid) = @rows.key?(pid.to_i)

        # @param pid [Integer] the root of the tree, a session's own process
        # @return [Tree] the tree's memory in MB, its CPU percent, its process count and its MCP
        #   servers
        def tree(pid)
          members = descendants(pid.to_i)
          Tree.new(memory_mb: (members.sum(&:rss_kb).to_f / KB_PER_MB).round, cpu: members.sum(&:cpu).round(1),
                   processes: members.size, mcp_servers: members.count { |member| member.command.match?(MCP) })
        end

        private

        def descendants(pid)
          root = @rows[pid]
          return [] unless root

          found = [root]
          queue = [pid]
          until queue.empty?
            kids = Array(@children[queue.shift])
            found.concat(kids)
            queue.concat(kids.map(&:pid))
          end
          found
        end

        # Every line of the `ps` text that reads as a process.
        def parsed(text) = text.to_s.each_line.filter_map { |line| row(line.chomp) }

        def row(line)
          match = LINE.match(line)
          return unless match

          Row.new(pid: match[1].to_i, ppid: match[2].to_i, rss_kb: match[3].to_i, cpu: match[4].to_f, command: match[5])
        end
      end
    end
  end
end
