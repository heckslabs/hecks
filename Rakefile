require "sdoc"
require "rdoc/task"

RDoc::Task.new do |rdoc|
  rdoc.generator = "sdoc"
  rdoc.main = "README.md"
  rdoc.title = "Hecks — Hexagonal DDD Framework for Ruby"
  rdoc.markup = "markdown"
  rdoc.rdoc_dir = "doc"
  rdoc.options << "--copy-files" << "hecks_logo.png"
  rdoc.rdoc_files.include("README.md", "FEATURES.md", "*/lib/**/*.rb", "docs/**/*.md")
end

namespace :parity do
  desc "i30 differential fuzzer — Ruby↔Rust runtime cascade parity"
  task :fuzz do
    args = ENV["FUZZ_ARGS"] || "--start 1 --count 200"
    sh "ruby -Ilib spec/parity/fuzz/fuzz_test.rb #{args}"
  end
end
