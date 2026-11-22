require "hecks/adapters/driving/resident/server"

# A resident of the primary checkout, loaded with nothing, for asking what it would serve.
module ControlProcessServer
  # @return [Hecks::Adapters::Driving::Resident] the resident namespace
  def resident = Hecks::Adapters::Driving::Resident

  # @param control [Boolean] whether it is the control process
  # @return [Hecks::Adapters::Driving::Resident::Server] a server that judges lines, binding nothing
  def judging_server(control)
    server = resident::Server.new(primary, File.join(primary, "exe/hecks"), control: control)
    server.instance_variable_set(:@environment, {})
    server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint, changed?: false))
    server
  end

  # @return [String, nil] why the server would not serve the line, nil when it would
  def refusal(env, argv, cwd = primary)
    server.send(:unservable, { script: File.join(primary, "exe/hecks"), env: env, argv: argv, cwd: cwd })
  end

  # Leaves the server with nothing asked of it for longer than its idle time.
  #
  # @return [void]
  def quiet_for_a_while
    server.instance_variable_set(:@settings, { idle_seconds: 0.0 })
    server.instance_variable_set(:@active, Time.now - 100)
  end
end
