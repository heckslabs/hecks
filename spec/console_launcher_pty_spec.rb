require "spec_helper"
require "pty"
require "rbconfig"
require "tmpdir"
require "timeout"

# `hecks console` through the generated launcher, typed into at a real terminal. IRB reads the
# process's own arguments for a script to run; the launcher's hold `console`, which IRB used to
# open as a file and then quit with no prompt. Calling `Hecks::CLI::Console` directly (as
# console_spec.rb does) never sees those arguments, so only this path catches it.
RSpec.describe "hecks console through the launcher, at a terminal" do
  PTY_PROMPT = /irb\(main\)/
  PTY_ANSWER = /PTY_STATUS=available/

  # Reads until the pattern shows or the time runs out.
  def read_until(reader, pattern, seconds:)
    seen = +""
    Timeout.timeout(seconds) do
      seen << reader.readpartial(4096) until seen.match?(pattern)
    end
    seen
  rescue Timeout::Error, Errno::EIO, EOFError
    seen
  end

  # The environment of a console with no saved history and no database to reach.
  def console_env(dir)
    irbrc = File.join(dir, "irbrc")
    File.write(irbrc, "IRB.conf[:SAVE_HISTORY] = nil\n")
    { "IRBRC" => irbrc, "TERM" => "dumb", "HECKS_ENVIRONMENT" => nil,
      "PGHOST" => "/nonexistent-postgres-socket-dir", "PGPORT" => "1" }
  end

  def expect_quiet_prompt(reader)
    prompt = read_until(reader, PTY_PROMPT, seconds: 90)
    expect(prompt).to match(PTY_PROMPT), "no prompt appeared; the console printed:\n#{prompt}"
    expect(prompt).not_to include("process_manager"), "wiring notes about hecks's own chapters opened the session"
  end

  def expect_typed_input_evaluated(reader, writer)
    writer.puts 'order = Order.create_pizza!(name: "Margherita", pizza: { price_cents: { cents: 1200 }, size: "large" })'
    writer.puts 'puts "PTY_STATUS=" + order.status'
    answer = read_until(reader, PTY_ANSWER, seconds: 30)
    expect(answer).to match(PTY_ANSWER), "typed input was not evaluated; the console printed:\n#{answer}"
  end

  def expect_exit_without_record(reader, writer, pid)
    writer.puts "exit"
    after = read_until(reader, /\A\z-never/, seconds: 30)
    Process.wait(pid)
    expect(after).not_to include('"status"'), "the session ended with a settled record:\n#{after}"
  end

  # Spawns `hecks console` at a pseudo-terminal and yields its reader, writer and pid.
  def with_console
    Dir.mktmpdir do |dir|
      PTY.spawn(console_env(dir), RbConfig.ruby, "exe/hecks", "console", chdir: InMemoryDomain::ROOT) do |*terminal|
        yield(*terminal)
      end
    end
  end

  it "reaches a prompt quietly, evaluates what is typed, and ends without a record", :aggregate_failures do
    with_console do |reader, writer, pid|
      expect_quiet_prompt(reader)
      expect_typed_input_evaluated(reader, writer)
      expect_exit_without_record(reader, writer, pid)
    end
  end
end
