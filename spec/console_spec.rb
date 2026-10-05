require "open3"
require "rbconfig"
require "hecks/cli/console"

# `Hecks::CLI::Console` (Operation.OpenConsole) runs as a real subprocess with its
# IRB session fed on stdin. Postgres is pointed at a port nothing listens
# on, for the child process only: the bare console must dispatch a pizza
# with no database server reachable (ADR 0073), while an explicit
# `examples/directory` still boots that directory's own `PostgresEra` wiring.
RSpec.describe "Hecks::CLI::Console" do
  # The child's whole program: the library entry point, with the domain argument passed through.
  # A prefixed constant name: top-level spec constants share one namespace, and
  # load_hygiene_spec.rb refuses a collision.
  CONSOLE_CHILD = '$LOAD_PATH.unshift("lib"); require "hecks/cli/console"; Hecks::CLI::Console.call(ARGV.first)'.freeze

  # `IRBRC` pins an empty rc file so the reader's own `~/.irbrc` cannot
  # change what the session prints.
  CONSOLE_NO_POSTGRES_ENV = {
    "PGHOST" => "/nonexistent-postgres-socket-dir",
    "PGPORT" => "1",
    "IRBRC"  => File::NULL
  }.freeze

  CONSOLE_PIZZA_SESSION = <<~RUBY.freeze
    order = Order.create_pizza!(name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
    order.add_topping!(topping: { value: "Basil" }, amount: { value: 3 })
    order.purchase!(customer_name: { value: "Chris" }, amount: { cents: 1200 })
    puts "RESULT=\#{order.status}/\#{order.events.last.name}"
  RUBY

  def run_console(*args, stdin:)
    Open3.capture3(CONSOLE_NO_POSTGRES_ENV, RbConfig.ruby, "-e", CONSOLE_CHILD, *args,
                   stdin_data: stdin, chdir: InMemoryDomain::ROOT)
  end

  it "boots pizzas on the in-memory adapter by default and dispatches with no Postgres" do
    stdout, stderr, status = run_console(stdin: CONSOLE_PIZZA_SESSION)

    expect(status).to be_success, stderr
    expect(stdout).to include("RESULT=sold/PizzaPurchased")
    expect(stderr).not_to include("PostgresEra")
  end

  it "still boots an explicit domain directory as that directory is wired" do
    _stdout, stderr, status = run_console("examples/directory", stdin: "exit\n")

    expect(status).not_to be_success
    expect(stderr).to include("cannot bind PostgresEra")
  end

  describe ".overview" do
    it "prints each aggregate's description under its commands" do
      stdout, stderr, status = run_console(stdin: "exit\n")

      expect(status).to be_success, stderr
      expect(stdout).to match(/^    Order: .*\n      An order that gathers toppings/)
    end
  end

  describe ".banner" do
    it "offers the pizzas session, in the bare form the README uses, only for the pizzas domain" do
      shown = Hecks::CLI::Console.banner

      expect(shown).to include('Order.create_pizza!(name: "Margherita"')
      expect(shown).not_to include("{ value:")
    end

    it "names no pizzas for any other domain" do
      expect(Hecks::CLI::Console.banner("examples/banking")).not_to include("pizza")
    end
  end
end
