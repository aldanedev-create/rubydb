# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

url = URI(ENV.fetch("RUBYDB_HTTP_URL", "http://127.0.0.1:3002/products.json"))
threads = Integer(ENV.fetch("RUBYDB_HTTP_THREADS", "4"), 10)
requests_per_thread = Integer(ENV.fetch("RUBYDB_HTTP_REQUESTS", "250"), 10)
timeout = Integer(ENV.fetch("RUBYDB_HTTP_TIMEOUT", "10"), 10)

def percentile(values, fraction)
  return 0.0 if values.empty?

  sorted = values.sort
  sorted[[((sorted.length - 1) * fraction).round, 0].max]
end

latencies = Queue.new
failures = Queue.new
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

workers = threads.times.map do |worker_id|
  Thread.new do
    Net::HTTP.start(url.host, url.port, open_timeout: timeout, read_timeout: timeout) do |http|
      requests_per_thread.times do |request_number|
        request_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = http.get(url.request_uri, {"Accept" => "application/json"})
        latency = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - request_started) * 1000.0
        if response.code.to_i == 200
          latencies << latency
        else
          failures << {worker: worker_id, request: request_number, status: response.code, body: response.body.to_s[0, 200]}
        end
      end
    end
  rescue => error
    failures << {worker: worker_id, class: error.class.name, message: error.message}
  end
end
workers.each(&:join)

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
samples = []
samples << latencies.pop until latencies.empty?
failures_found = []
failures_found << failures.pop until failures.empty?
total = threads * requests_per_thread

result = {
  url: url.to_s,
  threads: threads,
  requests: total,
  completed: samples.length,
  errors: failures_found.length,
  elapsed_seconds: elapsed.round(3),
  throughput_requests_per_second: (samples.length / elapsed).round(2),
  latency_ms: {
    p50: percentile(samples, 0.50).round(3),
    p95: percentile(samples, 0.95).round(3),
    p99: percentile(samples, 0.99).round(3),
    max: samples.max.to_f.round(3)
  },
  first_errors: failures_found.first(10)
}
puts JSON.pretty_generate(result)
exit 1 unless failures_found.empty?
