# frozen_string_literal: true

# Runs the concurrent insert/durability workload repeatedly. It is intended for
# a controlled pre-release or deployment environment, not as an in-process unit
# benchmark: each round gets a fresh database and must pass its durability check.

require "json"
require "open3"
require "rbconfig"

def positive_integer(name, default)
  value = Integer(ENV.fetch(name, default.to_s), 10)
  raise ArgumentError, "#{name} must be at least 1" if value < 1

  value
rescue ArgumentError
  raise ArgumentError, "#{name} must be an integer at least 1"
end

rounds = positive_integer("RUBYDB_SOAK_ROUNDS", 5)
threads = positive_integer("RUBYDB_SOAK_THREADS", 8)
operations = positive_integer("RUBYDB_SOAK_OPERATIONS", 1_000)
payload_bytes = Integer(ENV.fetch("RUBYDB_SOAK_PAYLOAD_BYTES", "256"), 10)
raise ArgumentError, "RUBYDB_SOAK_PAYLOAD_BYTES must be non-negative" if payload_bytes.negative?

workload = File.expand_path("concurrent_workload.rb", __dir__)
results = rounds.times.map do |round|
  environment = {
    "RUBYDB_WORKLOAD_THREADS" => threads.to_s,
    "RUBYDB_WORKLOAD_OPERATIONS" => operations.to_s,
    "RUBYDB_WORKLOAD_PAYLOAD_BYTES" => payload_bytes.to_s
  }
  output, error, status = Open3.capture3(environment, RbConfig.ruby, workload)
  raise "soak round #{round + 1} failed: #{error}\n#{output}" unless status.success?

  result = JSON.parse(output.lines.last, symbolize_names: true)
  expected_rows = threads * operations
  raise "soak round #{round + 1} lost rows" unless result[:durable_rows] == expected_rows

  result.merge(round: round + 1)
end

total_inserts = results.sum { |result| result[:total_inserts] }
total_duration = results.sum { |result| result[:duration_seconds] }
puts JSON.generate(
  rounds: rounds,
  threads: threads,
  operations_per_thread: operations,
  total_inserts: total_inserts,
  durable_rows_verified: results.sum { |result| result[:durable_rows] },
  duration_seconds: total_duration.round(4),
  average_operations_per_second: (total_inserts * 2 / total_duration).round(2),
  rounds_detail: results
)
