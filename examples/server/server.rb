# frozen_string_literal: true

# Start a RubyDB TCP server. Keep this process running and use client.rb from
# another terminal. Set RUBYDB_PORT or RUBYDB_DATA_DIR to customize it.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "fileutils"
require "rubydb"

port = Integer(ENV.fetch("RUBYDB_PORT", "7432"), 10)
data_dir = File.expand_path(ENV.fetch("RUBYDB_DATA_DIR", "tmp/server_data"), __dir__)
FileUtils.mkdir_p(data_dir)

server = RubyDB::Server::Server.new(
  host: ENV.fetch("RUBYDB_HOST", "127.0.0.1"),
  port: port,
  data_dir: data_dir,
  log_dir: File.join(data_dir, "log"),
  pid_file: File.join(data_dir, "rubydb.pid"),
  min_workers: 1,
  max_workers: 4
)
unless server.engine.table_exists?(:messages)
  server.engine.create_table("messages", [
    RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false),
    RubyDB::Catalog::Column.new("body", :varchar, null: false)
  ])
end

shutdown_requested = false
%w[INT TERM].each { |signal| Signal.trap(signal) { shutdown_requested = true } }
server.start
puts "Server example listening on #{server.config[:host]}:#{port}"
sleep 0.25 while server.running? && !shutdown_requested
server.stop if server.running?
