# wrapper_helper.rb — extract + invoke the dispatch/heki_write functions
# from any of the 5 body daemon shells (mindstream, pulse_organs,
# rem_branch, nrem_branch, consolidate).
#
# Contract :
#   - extract_function(shell_path, fn_name) returns the exact bash source
#     of the named function (between `^fn_name() {` and the first
#     bare `^}`), with a trailing newline.
#   - invoke(shell:, fn:, args:, env:) writes a tiny bash harness that
#     defines HECKS / AGG / ERR_LOG / HECKS_INFO from env, sources the
#     extracted function, calls it with args, and returns
#     [stdout, stderr, exit_status]. Any extra env vars passed in env:
#     are exported into the bash subprocess.
#
# Usage :
#   helper = WrapperHelper.new(
#     shell: '/abs/body/mindstream.sh',
#     hecks_bin: '/abs/hecks-life',
#     agg_dir: '/abs/body',
#     err_log: '/tmp/foo_err.log',
#     hecks_info: '/tmp/iso_info'
#   )
#   stdout, stderr, status = helper.invoke(:dispatch,
#     ['Consciousness.AdvanceLightToRem', 'name=consciousness'])

require 'open3'
require 'tmpdir'

class WrapperHelper
  # i75-pulse-organs : pulse_organs.sh removed from this list when the
  # Pulse PM (body/pulse_organs/pulse_organs.bluebook) replaced the
  # shell. The remaining four shells share the byte-identical wrapper
  # contract until they too retire (sibling i75 PRs).
  WRAPPER_SHELLS = %w[
    body/mindstream.sh
    body/rem_branch.sh
    body/nrem_branch.sh
    body/consolidate.sh
  ].freeze

  attr_reader :shell, :hecks_bin, :agg_dir, :err_log, :hecks_info

  def initialize(shell:, hecks_bin:, agg_dir:, err_log:, hecks_info:)
    @shell = shell
    @hecks_bin = hecks_bin
    @agg_dir = agg_dir
    @err_log = err_log
    @hecks_info = hecks_info
  end

  # Pull the source of `fn_name() { ... }` from the given shell file.
  # Greedy-matches the first `^}` after the opening line. Doc comments
  # above the function are NOT included (function source only).
  def self.extract_function(shell_path, fn_name)
    src = File.read(shell_path)
    open_re = /^#{Regexp.escape(fn_name)}\(\)\s*\{$/
    lines = src.lines
    start_idx = lines.index { |l| l.match?(open_re) }
    raise "function #{fn_name} not found in #{shell_path}" if start_idx.nil?

    end_idx = (start_idx + 1...lines.length).find { |i| lines[i].rstrip == '}' }
    raise "function #{fn_name} not closed in #{shell_path}" if end_idx.nil?

    lines[start_idx..end_idx].join
  end

  # Run dispatch or heki_write inside a controlled bash harness.
  # Returns [stdout, stderr, status (Process::Status)].
  def invoke(fn, args)
    fn_src = self.class.extract_function(@shell, fn.to_s)
    # Name the harness file with the same basename as the source shell.
    # The wrapper logs `$(basename "$0")` ; preserving the basename
    # keeps the contract test honest — the log line shows the script
    # the function was lifted from.
    Dir.mktmpdir('wrapper_harness_') do |dir|
      harness = File.join(dir, File.basename(@shell))
      File.write(harness, harness_source(fn, fn_src, args))
      File.chmod(0o755, harness)
      stdout, stderr, status = Open3.capture3(
        { 'HECKS_DAEMON_ERR_LOG' => @err_log,
          'HECKS_INFO' => @hecks_info,
          'HECKS_DAEMON' => '1' },
        '/bin/bash', harness
      )
      [stdout, stderr, status]
    end
  end

  private

  def harness_source(fn, fn_src, args)
    quoted_args = args.map { |a| escape_arg(a) }.join(' ')
    <<~BASH
      #!/bin/bash
      # harness — defines the env the wrapper functions assume, sources
      # one of the 5 production wrapper functions verbatim, invokes it,
      # propagates exit status. Mimics what the daemon shells do at
      # the top of their main loop.
      HECKS=#{escape_arg(@hecks_bin)}
      AGG=#{escape_arg(@agg_dir)}
      ERR_LOG=#{escape_arg(@err_log)}
      mkdir -p "$(dirname "$ERR_LOG")" 2>/dev/null || true

      #{fn_src}
      #{fn} #{quoted_args}
      exit $?
    BASH
  end

  def escape_arg(s)
    "'" + s.to_s.gsub("'", %q('\\'')) + "'"
  end
end
