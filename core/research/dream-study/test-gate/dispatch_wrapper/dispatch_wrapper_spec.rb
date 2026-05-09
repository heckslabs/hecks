# dispatch_wrapper_spec.rb — Phase 0e contract lock.
#
# The body's 5 daemon shells (mindstream, pulse_organs, rem_branch,
# nrem_branch, consolidate) each carry a byte-identical copy of the
# `dispatch()` and `heki_write()` wrapper functions. Today the
# duplication is invisible — drift between copies could ship without
# anyone noticing. These tests lock the contract :
#
#   1. GivenFailed short-circuits silently — exit 0, no log, no concern.
#   2. Real dispatch failure (UnknownCommand / LifecycleViolation /
#      AggregateNotFound) → non-zero exit + verbatim stderr + tagged
#      `dispatch failed:` line in $ERR_LOG + Doctor.NoteConcern with
#      failure_kind=DispatchFailed.
#   3. Successful dispatch → exit 0, log untouched, no concern.
#   4. heki_write failure → non-zero exit + tagged `heki write failed:`
#      line + Doctor.NoteConcern with failure_kind=HekiWriteFailed.
#   5. Doctor dispatch failure (no doctor.bluebook in AGG) does NOT
#      cascade — wrapper still returns 1 from the original failure.
#   6. All 5 shells carry byte-identical dispatch + heki_write source.
#
# Production wrapper paths : body/mindstream.sh:100 (the canonical
# definition) ; the other four are byte-identical copies. This spec
# is the future de-duplication PR's target.
#
# Run :
#   cd dream-study/test-gate/dispatch_wrapper
#   rspec dispatch_wrapper_spec.rb

require 'tmpdir'
require 'time'
require 'fileutils'
require 'json'
require_relative 'lib/wrapper_helper'

MIETTE_ROOT = File.expand_path('../../..', __dir__)
HECKS_BIN = File.expand_path(
  '../hecks/rust/target/release/hecks-life', MIETTE_ROOT
)
AGG_DIR = File.join(MIETTE_ROOT, 'body')
CANONICAL_SHELL = File.join(MIETTE_ROOT, 'body/mindstream.sh')

RSpec.describe 'dispatch wrapper contract' do
  let(:tmp_info) { Dir.mktmpdir('dispatch_wrapper_info_') }
  let(:err_log) { File.join(tmp_info, 'daemon_errors.log') }
  let(:helper) do
    WrapperHelper.new(
      shell: CANONICAL_SHELL, hecks_bin: HECKS_BIN, agg_dir: AGG_DIR,
      err_log: err_log, hecks_info: tmp_info
    )
  end

  after { FileUtils.rm_rf(tmp_info) if File.exist?(tmp_info) }

  def err_log_contents = File.exist?(err_log) ? File.read(err_log) : ''

  # `heki latest` flattens noted_concerns to "[N items]" — for the
  # field shape we read the full record list and unfold each row's
  # noted_concerns array.
  def doctor_concerns
    heki = File.join(tmp_info, 'doctor/doctor.heki')
    return [] unless File.exist?(heki)
    list = `#{HECKS_BIN} heki list #{heki} --format json 2>/dev/null`
    return [] if list.strip.empty?
    JSON.parse(list).flat_map { |row| row['noted_concerns'] || [] }
  rescue JSON::ParserError
    []
  end

  it '1. GivenFailed short-circuits — exit 0, log untouched, no concern' do
    _stdout, _stderr, status = helper.invoke(
      :dispatch,
      ['Consciousness.AdvanceLightToRem', 'name=consciousness']
    )
    expect(status.exitstatus).to eq(0)
    expect(err_log_contents).to eq('')
    expect(doctor_concerns).to be_empty
  end

  it '2. Real failure — non-zero exit, stderr+tag in log, Doctor concern recorded' do
    _stdout, _stderr, status = helper.invoke(
      :dispatch, ['NoSuchAggregate.NoSuchCommand', 'foo=bar']
    )
    expect(status.exitstatus).to eq(1)
    log = err_log_contents
    expect(log).to match(/UnknownCommand|dispatch error/)
    expect(log).to match(
      /\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\] mindstream\.sh line \d+: dispatch failed: NoSuchAggregate\.NoSuchCommand/
    )
    concerns = doctor_concerns
    expect(concerns).not_to be_empty
    last = concerns.last
    expect(last['aggregate_name']).to eq('NoSuchAggregate')
    expect(last['command_name']).to eq('NoSuchCommand')
    expect(last['failure_kind']).to eq('DispatchFailed')
    expect(last['script']).to eq('mindstream.sh')
    expect(last['line']).to match(/^\d+$/)
    expect(last['noted_at']).to match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
  end

  it '3. Successful dispatch — exit 0, log untouched, no concern' do
    _stdout, _stderr, status = helper.invoke(
      :dispatch,
      ['Doctor.RecordCheckup', "checkup_at=#{Time.now.utc.iso8601}"]
    )
    expect(status.exitstatus).to eq(0)
    expect(err_log_contents).to eq('')
    expect(doctor_concerns).to be_empty
  end

  it '4. heki_write failure — non-zero exit, tagged log line, HekiWriteFailed concern' do
    _stdout, _stderr, status = helper.invoke(
      :heki_write, ['no-such-subcmd', '/tmp/never_written.heki', 'k=v']
    )
    expect(status.exitstatus).to eq(1)
    log = err_log_contents
    expect(log).to match(/Unknown heki command|hecks-life heki/)
    expect(log).to match(
      /\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\] mindstream\.sh line \d+: heki write failed: no-such-subcmd/
    )
    concerns = doctor_concerns
    expect(concerns).not_to be_empty
    last = concerns.last
    expect(last['failure_kind']).to eq('HekiWriteFailed')
    expect(last['aggregate_name']).to eq('heki')
    expect(last['command_name']).to eq('no-such-subcmd')
  end

  it '5. Doctor dispatch failure does NOT cascade — outer return reflects original failure' do
    # Stand a fake hecks-life that fails on Doctor.* and proxies the rest
    # to the real binary. The wrapper's `|| true` on the Doctor call
    # must keep the outer return at 1 (the original dispatch's status).
    shim_dir = Dir.mktmpdir('hecks_shim_')
    shim = File.join(shim_dir, 'hecks-life')
    File.write(shim, <<~SHIM)
      #!/bin/bash
      # Test shim — fail loudly on Doctor.* dispatches, proxy everything
      # else through to the real hecks-life. Used to simulate Doctor
      # being unreachable during boot.
      for arg in "$@"; do
        case "$arg" in
          Doctor.*) echo "shim: Doctor unreachable" >&2; exit 99 ;;
        esac
      done
      exec "#{HECKS_BIN}" "$@"
    SHIM
    File.chmod(0o755, shim)
    shim_helper = WrapperHelper.new(
      shell: CANONICAL_SHELL, hecks_bin: shim, agg_dir: AGG_DIR,
      err_log: err_log, hecks_info: tmp_info
    )
    _stdout, _stderr, status = shim_helper.invoke(
      :dispatch, ['NoSuchAggregate.NoSuchCommand']
    )
    # Outer return reflects the original dispatch's failure (1) — the
    # Doctor shim's exit-99 didn't cascade up.
    expect(status.exitstatus).to eq(1)
    expect(err_log_contents).to match(/dispatch failed: NoSuchAggregate\.NoSuchCommand/)
    # The Doctor shim's own stderr lands in the log too (proves Doctor
    # was attempted) but the wrapper return was unchanged.
    expect(err_log_contents).to match(/shim: Doctor unreachable/)
    # No doctor.heki recorded since the shim refused.
    expect(File.exist?(File.join(tmp_info, 'doctor/doctor.heki'))).to be(false)
  ensure
    FileUtils.rm_rf(shim_dir) if shim_dir
  end

  it '6. All 5 shells carry byte-identical dispatch + heki_write source' do
    canonical_dispatch = WrapperHelper.extract_function(CANONICAL_SHELL, 'dispatch')
    canonical_heki = WrapperHelper.extract_function(CANONICAL_SHELL, 'heki_write')
    WrapperHelper::WRAPPER_SHELLS.each do |rel|
      path = File.join(MIETTE_ROOT, rel)
      expect(WrapperHelper.extract_function(path, 'dispatch')).to eq(canonical_dispatch),
        "dispatch() in #{rel} drifted from canonical (mindstream.sh)"
      expect(WrapperHelper.extract_function(path, 'heki_write')).to eq(canonical_heki),
        "heki_write() in #{rel} drifted from canonical (mindstream.sh)"
    end
  end
end
