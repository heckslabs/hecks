require "hecks/fuzzing/delivery_simulation"

# Boots the Hecks domain once in Memory and replays schedules of simulated agents against it.
# One runtime holds the vendored `Landing` and this repository's `SendTrain`.
module SimulatedDelivery
  Simulation = Hecks::Fuzzing::DeliverySimulation
  Generator = Simulation::Generator

  # The one runtime the groups that include this share.
  def self.booted
    @booted ||= yield
  end

  # A `Worktrees` stand-in that notes the registry its ask runs under before it gives up its turn,
  # and whether the same one is there after: the runtime keeps it per Fiber.
  class Noting
    def initialize(world, seen)
      @world = world
      @seen = seen
    end

    def merge(**held)
      before = Hecks::Runtime::Asking.registry
      @world.turn
      branch = Simulation::StandIns.plain(held[:branch])
      @seen << [branch, !before.nil? && before.equal?(Hecks::Runtime::Asking.registry)]
      { outcome: { value: "merged" }, checkout: { value: "/sim" }, branch: { value: branch },
        landed: { value: @world.repository.land(branch) }, report: { value: "noted" } }
    end
  end

  # Lands by reading main, giving up its turn, and then writing main without another look: a
  # landing that began in between is written over. It is broken on purpose, to be found.
  class Lossy
    def initialize(world)
      @world = world
    end

    def merge(**held)
      git = @world.repository
      branch = Simulation::StandIns.plain(held[:branch])
      @world.turn
      before = git.tip("main")
      @world.turn
      landed = git.write_ref("main", git.merge(before, git.tip(branch)))
      { outcome: { value: "merged" }, checkout: { value: "/sim" }, branch: { value: branch },
        landed: { value: landed }, report: { value: "written over main" } }
    end
  end

  def hecks = SimulatedDelivery.booted { boot_hecks_in_memory }

  def simulation(**) = Simulation.new(hecks, **)

  def lossy = simulation(stand_ins: { "Worktrees" => ->(world) { Lossy.new(world) } })

  def turns(*agents) = agents.map { |agent| Generator.advance(agent) }

  def faulted(kind, *agents) = [Generator.fault(kind)] + turns(*agents)

  def interleaved
    seen = []
    simulation(stand_ins: { "Worktrees" => ->(world) { Noting.new(world, seen) } }).run(turns("a", "b", "b", "a"))
    seen
  end

  def crowd(seed) = simulation.run(Generator.call(seed: seed, fault_rate: 0.1))

  def fields(result) = result.divergences.map { |divergence| divergence[:field] }
end
