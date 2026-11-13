require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "tmpdir"

# Four processes race for the line: they land in the order they joined, one at a time.
RSpec.describe Hecks::Adapters::GitLanding::Lineup do
  let(:dir) { Dir.mktmpdir("hecks-landing-processes") }
  let(:log) { File.join(dir, "log") }

  let(:script) do
    <<~RUBY
      Hecks::Adapters::DeliveryLibrary.require("git_landing/lineup")
      mark = lambda do |text|
        File.open(ARGV[2], "a") { |file| file.flock(File::LOCK_EX) && file.puts(text) }
        puts text
        $stdout.flush
      end
      lineup = Hecks::Adapters::GitLanding::Lineup.new(ARGV[0], locks: [], say: mark, wait_minutes: 1)
      lineup.stand(ARGV[1], onto: "main", checkout: ARGV[0]) do
        mark.call("start " + ARGV[1])
        $stdin.gets
        mark.call("end " + ARGV[1])
      end
    RUBY
  end

  after { FileUtils.remove_entry(dir) }

  def start(name)
    IO.popen(["ruby", "-I", File.expand_path("../lib", __dir__), "-e", script, dir, name, log], "r+")
  end

  def hear(child, text)
    Timeout.timeout(20) { loop { break if child.gets.include?(text) } }
  end

  def join_in_turn(names)
    children = names.each_with_index.map do |name, index|
      start(name).tap { |child| hear(child, index.zero? ? "start #{name}" : "#{name} is #{%w[_ 2nd 3rd 4th][index]} in line") }
    end
    # Let each child finish speaking before its pipe closes; a write to a closed pipe kills it.
    children.each do |child|
      child.puts("go")
      child.close_write
      child.read
      child.close
    end
  end

  it "lands in the order the processes joined, one at a time" do
    names = %w[w1 w2 w3 w4]
    join_in_turn(names)

    marks = File.readlines(log, chomp: true).grep(/\A(start|end) /)
    expect(marks).to eq(names.flat_map { |name| ["start #{name}", "end #{name}"] })
  end
end
