require "open3"
require "rbconfig"

# bin/console is a script, so this runs it as a real subprocess with its
# IRB session fed on stdin. Postgres is pointed at a port nothing listens
# on, for the child process only: the bare console must dispatch a pizza
# with no database server reachable (ADR 0073), while an explicit
# `examples/pizzas` still boots that directory's own `PostgresEra` wiring.
RSpec.describe "bin/console" do
  # A prefixed name rather than a bare `SCRIPT`: top-level spec constants
  # share one namespace, and load_hygiene_spec.rb refuses a collision.
  BIN_CONSOLE_SCRIPT = File.join(InMemoryDomain::ROOT, "bin/console").freeze

  # `IRBRC` pins an empty rc file so the reader's own `~/.irbrc` cannot
  # change what the session prints.
  BIN_CONSOLE_NO_POSTGRES_ENV = {
    "PGHOST" => "/nonexistent-postgres-socket-dir",
    "PGPORT" => "1",
    "IRBRC"  => File::NULL
  }.freeze

  BIN_CONSOLE_PIZZA_SESSION = <<~RUBY.freeze
    order = Order.create_pizza!(name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
    order.add_topping!(topping: { value: "Basil" }, amount: { value: 3 })
    order.purchase!(customer_name: { value: "Chris" }, amount: { cents: 1200 })
    puts "RESULT=\#{order.status}/\#{order.events.last.name}"
  RUBY

  def run_console(*args, stdin:)
    Open3.capture3(BIN_CONSOLE_NO_POSTGRES_ENV, RbConfig.ruby, BIN_CONSOLE_SCRIPT, *args,
                   stdin_data: stdin, chdir: InMemoryDomain::ROOT)
  end

  it "boots pizzas on the in-memory adapter by default and dispatches with no Postgres" do
    stdout, stderr, status = run_console(stdin: BIN_CONSOLE_PIZZA_SESSION)

    expect(status).to be_success, stderr
    expect(stdout).to include("RESULT=sold/PizzaPurchased")
    expect(stderr).not_to include("PostgresEra")
  end

  it "still boots an explicit domain directory as that directory is wired" do
    _stdout, stderr, status = run_console("examples/pizzas", stdin: "exit\n")

    expect(status).not_to be_success
    expect(stderr).to include("cannot bind PostgresEra")
  end
end
