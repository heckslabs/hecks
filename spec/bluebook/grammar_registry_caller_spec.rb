require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# The language's grammar is built once per process, by whichever code asks for it first. A caller
# bound by an enclosing `Hecks.as_caller` must not reach the language's own `Language`-role
# commands: they would be refused, and the grammar would be memoized without the chapters those
# refusals dropped (the Paging chapter, so no `limit`), for every boot after it in that process.
# A fresh interpreter with cold caches is the only place the first build can be observed.
RSpec.describe "the grammar built while a caller is bound" do
  # The program that asks for the grammar for the first time inside `as_caller` and prints what it
  # holds.
  def first_build_script(role)
    <<~RUBY
      require "hecks"
      Hecks.as_caller(role: #{role.inspect}) do
        grammar = Hecks::Bluebook::MetaValidator
        words = grammar::SyntaxBoot.call[:keywords].map { |row| row[:word] }
        puts [grammar.grammar_registry.bluebooks.keys.sort.join(","), words.include?("limit")].join("|")
      end
    RUBY
  end

  # Runs the program in a child process whose caches are empty, so nothing answers for the build.
  def run_with_cold_caches(script)
    Dir.mktmpdir("hecks-grammar-caller") do |cache|
      env = { "HECKS_CACHE_DIR" => cache, "XDG_CACHE_HOME" => cache, "HECKS_ENVIRONMENT" => "memory" }
      Open3.capture3(env, RbConfig.ruby, "-I", File.join(InMemoryDomain::ROOT, "lib"), "-e", script, chdir: InMemoryDomain::ROOT)
    end
  end

  it "holds every chapter and the words they admit, as when no caller is bound", :aggregate_failures, :process do
    out, err, status = run_with_cold_caches(first_build_script("Customer"))

    expect(status).to be_success, err
    expect(out.strip).to eq("Adapter,Bluebook,Hecksagon,Paging,Port,Translation,World|true")
  end
end
