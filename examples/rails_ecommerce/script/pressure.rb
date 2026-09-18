# frozen_string_literal: true

require "json"
require_relative "../config/environment"

threads = Integer(ENV.fetch("RUBYDB_PRESSURE_THREADS", "1"), 10)
operations_per_thread = Integer(ENV.fetch("RUBYDB_PRESSURE_OPERATIONS", "250"), 10)
mode = ENV.fetch("RUBYDB_PRESSURE_MODE", "read").downcase
write_ratio = Float(ENV.fetch("RUBYDB_PRESSURE_WRITE_RATIO", "0.10"))
raise "RUBYDB_PRESSURE_THREADS must be positive" unless threads.positive?
raise "RUBYDB_PRESSURE_OPERATIONS must be positive" unless operations_per_thread.positive?
raise "RUBYDB_PRESSURE_MODE must be read, write, or mixed" unless %w[read write mixed].include?(mode)

if threads > 1 && ENV.fetch("RUBYDB_EMBEDDED", "true") == "true"
  warn "Warning: embedded mode has one process owner. Use RUBYDB_EMBEDDED=false with a RubyDB server for concurrent pressure."
end

categories = Product.where(active: true).distinct.pluck(:category)
raise "seed data first: no active products found" if categories.empty?

def percentile(values, fraction)
  return 0.0 if values.empty?

  sorted = values.sort
  sorted[[((sorted.length - 1) * fraction).round, 0].max]
end

def read_workload(categories, random)
  category = categories[random.rand(categories.length)]
  case random.rand(4)
  when 0
    Product.active.in_category(category).order(price_cents: :asc).limit(50).pluck(:id, :name, :price_cents)
  when 1
    Product.active.where("name LIKE ?", "%Product #{random.rand(1..50)}%").order(:id).limit(25).to_a
  when 2
    Order.completed.group(:status).count
  else
    Order.includes(:customer, :order_items).order(id: :desc).limit(10).to_a.each do |order|
      order.customer.name
      order.order_items.sum(&:line_total_cents)
    end
  end
end

def write_workload(random)
  customer = Customer.order(:id).offset(random.rand([Customer.count, 1].max)).first || Customer.order(:id).first
  product = Product.active.order(:id).offset(random.rand([Product.active.count, 1].max)).first || Product.active.order(:id).first
  quantity = 1

  Order.transaction do
    order = customer.orders.create!(status: "paid", total_cents: product.price_cents * quantity)
    order.order_items.create!(product: product, quantity: quantity, unit_price_cents: product.price_cents)
    product.update!(stock: product.stock - quantity)
  end
end

latencies = Queue.new
errors = Queue.new
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

workers = threads.times.map do |worker_id|
  Thread.new do
    random = Random.new(20_260_918 + worker_id)
    ActiveRecord::Base.connection_pool.with_connection do
      operations_per_thread.times do
        operation_mode = if mode == "mixed"
          (random.rand < write_ratio) ? :write : :read
        else
          mode.to_sym
        end
        operation_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          if operation_mode == :write
            write_workload(random)
          else
            read_workload(categories, random)
          end
          latencies << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - operation_started) * 1000.0)
        rescue => error
          errors << {worker: worker_id, class: error.class.name, message: error.message}
        end
      end
    end
  end
end
workers.each(&:join)

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
samples = []
samples << latencies.pop until latencies.empty?
failures = []
failures << errors.pop until errors.empty?
total_operations = threads * operations_per_thread

result = {
  rubydb_version: RubyDB::VERSION,
  mode: mode,
  embedded: ENV.fetch("RUBYDB_EMBEDDED", "true") == "true",
  threads: threads,
  operations: total_operations,
  completed: samples.length,
  errors: failures.length,
  elapsed_seconds: elapsed.round(3),
  throughput_ops_per_second: (samples.length / elapsed).round(2),
  latency_ms: {
    p50: percentile(samples, 0.50).round(3),
    p95: percentile(samples, 0.95).round(3),
    p99: percentile(samples, 0.99).round(3),
    max: samples.max.to_f.round(3)
  },
  first_errors: failures.first(10)
}
puts JSON.pretty_generate(result)
exit 1 unless failures.empty?
