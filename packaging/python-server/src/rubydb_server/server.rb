# frozen_string_literal: true

# Private child entry point. The Python manager passes a local launch file.
require "json"
require "fileutils"
require "rubydb"

$stdout.sync = true
$stderr.sync = true
launch = JSON.parse(File.read(ARGV.fetch(0)))
data_dir = File.expand_path(launch.fetch("data_dir"))
control = File.join(data_dir, ".local")
credentials = JSON.parse(File.read(File.join(control, "config.json")))
state_path = File.join(control, "state.json")
run_id = launch.fetch("run_id")

def publish_state(path, state)
  temporary = "#{path}.#{Process.pid}.tmp"
  File.open(temporary, "w", 0o600) do |file|
    file.write(JSON.generate(state))
    file.flush
    file.fsync
  end
  File.rename(temporary, path)
end

state = {run_id: run_id, pid: Process.pid, ready: false}
publish_state(state_path, state)
shutdown_requested = false
%w[INT TERM].each { |signal| Signal.trap(signal) { shutdown_requested = true } }
server = nil
begin
  server = RubyDB::Server::Server.new(
    host: "127.0.0.1", port: Integer(launch.fetch("port")),
    data_dir: data_dir, log_dir: File.join(control, "log"),
    pid_file: File.join(control, "rubydb.pid"),
    min_workers: 1, max_workers: 4, max_connections: 32,
    worker_queue_size: 128, max_request_size: 4 * 1024 * 1024,
    authentication: {method: "password", credentials: {
      username: credentials.fetch("username"), password: credentials.fetch("password")
    }}
  )
  server.start
  publish_state(state_path, state.merge(ready: true, port: server.listener.port, version: RubyDB::VERSION))
  until shutdown_requested
    stop_path = File.join(control, "stop.json")
    if File.file?(stop_path)
      shutdown_requested = JSON.parse(File.read(stop_path))["run_id"] == run_id
    end
    sleep(0.1) unless shutdown_requested
  end
ensure
  server.stop if server&.running?
  # Keep the last PID and run identity to diagnose crashes or delayed shutdown.
  publish_state(state_path, state.merge(ready: false, stopped: true))
end
