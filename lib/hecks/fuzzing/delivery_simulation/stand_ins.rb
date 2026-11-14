# frozen_string_literal: true

require_relative "../outside_world"
require_relative "world"

module Hecks
  module Fuzzing
    class DeliverySimulation
      # What answers each port during a replay: a stand-in over the world for the landing, the
      # train and the outcome record, and `OutsideWorld` for every other port.
      #
      # `Runtime::AdapterLookup.standing_in` holds one stand-in for the whole process, so one
      # simulation replays at a time.
      class StandIns
        # The plain value of what a port ask hands over: a value object, a `{ value: }` hash or
        # the value itself.
        #
        # @param given [Object] an argument of a port ask
        # @return [Object, nil] its value
        def self.plain(given)
          return given.value if given.respond_to?(:value)

          given.is_a?(Hash) ? given[:value] : given
        end

        # @param world [World] the world the stand-ins answer from
        # @param overrides [Hash{String => #call}] by port name, what builds another stand-in
        #   from the world
        def initialize(world, overrides = {})
          @ports = { "Worktrees" => Worktrees.new(world), "Train" => Train.new(world),
                     "PushRecords" => PushRecords.new(world) }
          overrides.each { |port, build| @ports[port.to_s] = build.call(world) }
        end

        # @param port [String] the port asked
        # @param asked [String] what is being asked, worded into a refusal
        # @return [Object] the object to ask
        def call(port, asked) = @ports.fetch(port.to_s) { OutsideWorld.call(port, asked) }

        # The `Worktrees` port: a landing merged onto the simulated main.
        class Worktrees
          # @param world [World] the world answered from
          def initialize(world)
            @world = world
          end

          # Lands the branch, or refuses while main is red.
          #
          # @param held [Hash] the `Landing` record: `run` and `branch`
          # @return [Hash{Symbol => Hash}] `outcome:`, `checkout:`, `branch:`, `landed:`, `report:`
          # @raise [World::Refused] while main is red
          def merge(**held)
            run, branch = held.values_at(:run, :branch).map { |given| StandIns.plain(given) }
            @world.turn
            @world.refuse("Worktrees", run, "main is red: flag sim; #{branch} is not a fix") if @world.red?
            landed = @world.repository.land(branch)
            { outcome: { value: "merged" }, checkout: { value: "/sim" }, branch: { value: branch },
              landed: { value: landed }, report: { value: "#{branch} merged onto main at #{landed}" } }
          end
        end

        # The `Train` port: main boarded as a pull request, and that pull request read.
        class Train
          # @param world [World] the world answered from
          def initialize(world)
            @world = world
          end

          # Boards the commit main names: carried when the remote holds it, else queued.
          #
          # @param held [Hash] the `SendTrain` record: `run`
          # @return [Hash{Symbol => Hash}] `outcome:`, `checkout:`, `boarded:`, `commits:` and
          #   `report:`
          # @raise [World::Refused] while main is red
          def carry(**held)
            @world.turn
            @world.refuse("Train", StandIns.plain(held[:run]), "main is red: flag sim; nothing boards") if @world.red?
            git = @world.repository
            boarded = git.tip(Repository::MAIN)
            return answer("carried", boarded) if git.ancestor?(boarded, git.tip(Repository::ORIGIN))

            @world.open_pull(boarded)
            answer("queued", boarded)
          end

          # Reads a queued boarding's pull request: merged, failed, or still open.
          #
          # @param held [Hash] the `SendTrain` record: `boarded`
          # @return [Hash{Symbol => Hash}] `outcome:` and what `carry` answers with it
          def observe(**held)
            boarded = StandIns.plain(held[:boarded])
            @world.turn
            case @world.fate(boarded)
            when "green" then merged(boarded)
            when "red"   then { outcome: { value: "checks_failed" }, report: { value: "rspec failed on #{boarded}" } }
            else answer("open", boarded)
            end
          end

          private

          # A commit built on the remote's moves it, one the remote holds is merged already, and
          # one that is neither cannot merge: its pull request stays open.
          def merged(boarded)
            git = @world.repository
            remote = git.tip(Repository::ORIGIN)
            if git.ancestor?(remote, boarded) then git.move_ref(Repository::ORIGIN, boarded, expect: remote)
            elsif !git.ancestor?(boarded, remote)
              @world.strand_pull(boarded)
              return answer("open", boarded)
            end
            answer("merged", boarded).merge(pushed: { value: boarded })
          end

          def answer(outcome, boarded)
            { outcome: { value: outcome }, checkout: { value: "/sim" }, boarded: { value: boarded },
              commits: { value: 1 }, report: { value: "#{boarded} #{outcome}" } }
          end
        end

        # The `PushRecords` port: the store a boarding's outcome is recorded in.
        class PushRecords
          # @param world [World] the world answered from
          def initialize(world)
            @world = world
          end

          # Records the outcome, or refuses while another process holds the store.
          #
          # @param held [Hash] the `SendTrain` record: `run`
          # @return [Hash{Symbol => Hash}] `report:`
          # @raise [World::Refused] while the store is held
          def record_outcome(**held)
            run = StandIns.plain(held[:run])
            @world.refuse("PushRecords", run, "the store is held by another process: #{run} not recorded") if @world.held?
            { report: { value: "recorded #{run}" } }
          end
        end
      end
    end
  end
end
