require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/no_transport_in_runtime"

RSpec.describe RuboCop::Cop::Hecks::NoTransportInRuntime do
  include_context "with a Hecks cop under test"

  def message(code)
    "`#{code}` puts a transport detail inside the runtime. Move it into an adapter under " \
      "`lib/hecks/adapters/` and let the adapter call in, or pass the value in at boot."
  end

  # An HTTP client in the runtime ties domain execution to one transport.
  it "flags a network library" do
    expect_offense(<<~RUBY)
      require "net/http"
      ^^^^^^^^^^^^^^^^^^ #{message('require "net/http"')}
    RUBY
  end

  it "flags a require into the adapters" do
    expect_offense(<<~RUBY)
      require_relative "../adapters/driven/folder"
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ #{message('require_relative "../adapters/driven/folder"')}
    RUBY
  end

  it "flags a reach into Hecks::Adapters" do
    expect_offense(<<~RUBY)
      Adapters::Folder.new
      ^^^^^^^^ #{message("Adapters")}
    RUBY
  end

  it "flags a read of the process environment" do
    expect_offense(<<~RUBY)
      ENV["HECKS_ENVIRONMENT"]
      ^^^ #{message("ENV")}
    RUBY
  end

  it "flags standard input" do
    expect_offense(<<~RUBY)
      $stdin.read
      ^^^^^^ #{message("$stdin")}
    RUBY
  end

  it "does not flag a runtime require or a port" do
    expect_no_offenses(<<~RUBY)
      require "json"
      require_relative "../ports/loading"
      Ports::Loading.bootstrap
    RUBY
  end
end
