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

  it "reaches a prompt and evaluates what is typed" do
    Dir.mktmpdir do |dir|
      irbrc = File.join(dir, "irbrc")
      File.write(irbrc, "IRB.conf[:SAVE_HISTORY] = nil\n")
      env = { "IRBRC" => irbrc, "TERM" => "dumb", "HECKS_ENVIRONMENT" => nil,
              "PGHOST" => "/nonexistent-postgres-socket-dir", "PGPORT" => "1" }

      PTY.spawn(env, RbConfig.ruby, "exe/hecks", "console", chdir: InMemoryDomain::ROOT) do |reader, writer, pid|
        prompt = read_until(reader, PTY_PROMPT, seconds: 90)
        expect(prompt).to match(PTY_PROMPT), "no prompt appeared; the console printed:\n#{prompt}"

        writer.puts 'order = Order.create_pizza!(name: "Margherita", pizza: { price_cents: { cents: 1200 }, size: "large" })'
        writer.puts 'puts "PTY_STATUS=" + order.status'
        answer = read_until(reader, PTY_ANSWER, seconds: 30)
        expect(answer).to match(PTY_ANSWER), "typed input was not evaluated; the console printed:\n#{answer}"

        writer.puts "exit"
        Process.wait(pid)
      end
    end
  end
end
