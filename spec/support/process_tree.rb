require_relative "thread_parking"

# Finds and ends the processes a spec started, however they were reparented. A resident leaves its
# launcher's session, so it and the lines it forks (each in a process group of its own) are not
# descendants of the rspec run once the launcher has gone; they are found from the resident itself
# while it stands, and ended by process group so a grandchild listed late goes with its line.
module ProcessTree
  # One process as `ps` lists it.
  Row = Struct.new(:pid, :ppid, :pgid, :stat)

  # Seconds a process gets to be gone after it is killed.
  GONE_WITHIN = 10

  module_function

  # @return [Array<Row>] every process on the machine
  def rows
    `ps -A -o pid=,ppid=,pgid=,stat=`.lines.filter_map do |line|
      pid, ppid, pgid, stat = line.split
      Row.new(pid.to_i, ppid.to_i, pgid.to_i, stat) if stat
    end
  end

  # @param root [Integer] a process id
  # @param table [Array<Row>] the processes to search, every one by default
  # @return [Array<Row>] the processes under `root`, children and theirs, not `root` itself
  def descendants(root, table = rows)
    table.select { |row| row.ppid == root }.flat_map { |row| [row, *descendants(row.pid, table)] }
  end

  # @param pid [Integer] a process id
  # @return [Boolean] whether the process exists and is not a zombie
  def alive?(pid)
    row = rows.find { |each| each.pid == pid }
    !row.nil? && !row.stat.start_with?("Z")
  end

  # @param pid [Integer] a process id
  # @return [String] the command it runs, or an empty string when it is gone
  def command(pid)
    IO.popen(["ps", "-o", "command=", "-p", Integer(pid).to_s], &:read).strip
  end

  # Ends `pid` and everything under it. The process is stopped first, so it forks nothing more
  # while its tree is read; then each process group under it is killed, and `pid` last.
  #
  # @param pid [Integer] the resident (or other process) to end
  # @return [void]
  def end_tree(pid)
    Process.kill("STOP", pid)
    kids = descendants(pid)
    (kids.map(&:pgid).uniq - [Process.getpgrp, pid]).each { |group| signal("KILL", -group) }
    (kids.map(&:pid) + [pid]).each { |each| signal("KILL", each) }
    wait_gone([pid, *kids.map(&:pid)])
  rescue Errno::ESRCH
    nil
  end

  # Sends the signal, and does not mind a process that is already gone.
  #
  # @param name [String] the signal
  # @param pid [Integer] a process id, or a process group as its negative
  # @return [void]
  def signal(name, pid)
    Process.kill(name, pid)
  rescue SystemCallError
    nil
  end

  # @param pids [Array<Integer>] processes just killed
  # @return [void]
  def wait_gone(pids)
    ThreadParking.wait_for(timeout: GONE_WITHIN) { pids.none? { |pid| alive?(pid) } }
  rescue ThreadParking::NeverReached
    nil
  end
end
