# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "timeout"

module RubyDB
  module Accelerator
    # Owns one long-lived Go accelerator process. It deliberately uses a
    # private stdio channel instead of a public TCP listener: there is no port
    # to expose, and the Ruby process remains the database owner.
    class Manager
      DEFAULT_TIMEOUT = 30
      DEFAULT_MAX_FRAME_SIZE = 16 * 1024 * 1024
      PROTOCOL_VERSION = 1
      BINARY_VERSION = 1
      BINARY_MAGIC = "RDBB".b
      BINARY_ROWS_TYPE = 1
      BINARY_JOIN_TYPE = 2
      BINARY_SNAPSHOT_SCAN_TYPE = 3

      attr_reader :mode, :binary_path, :min_rows, :read_pipeline, :capabilities, :max_rows, :max_result_bytes

      def initialize(config = {})
        config = config.transform_keys(&:to_sym)
        @mode = (config[:mode] || ENV.fetch("RUBYDB_ACCELERATOR", "auto")).to_s.downcase
        validate_mode!
        @binary_path = resolve_binary(config[:binary] || ENV["RUBYDB_ACCELERATOR_BIN"])
        @timeout = Float(config[:timeout] || ENV.fetch("RUBYDB_ACCELERATOR_TIMEOUT", DEFAULT_TIMEOUT))
        @max_frame_size = Integer(config[:max_frame_size] || DEFAULT_MAX_FRAME_SIZE)
        @max_rows = Integer(config[:max_rows] || ENV.fetch("RUBYDB_ACCELERATOR_MAX_ROWS", "1000000"))
        @max_result_bytes = Integer(config[:max_result_bytes] || ENV.fetch("RUBYDB_ACCELERATOR_MAX_RESULT_BYTES", @max_frame_size))
        @min_rows = Integer(config[:min_rows] || ENV.fetch("RUBYDB_ACCELERATOR_MIN_ROWS", 256))
        @read_pipeline = (config[:read_pipeline] || ENV.fetch("RUBYDB_ACCELERATOR_READ_PIPELINE", "on")).to_s.downcase
        raise ArgumentError, "read_pipeline must be off or on" unless %w[off on].include?(@read_pipeline)
        raise ArgumentError, "min_rows must be non-negative" if @min_rows.negative?
        raise ArgumentError, "timeout must be positive" unless @timeout.positive?
        raise ArgumentError, "max_frame_size must be positive" unless @max_frame_size.positive?
        raise ArgumentError, "max_rows must be positive" unless @max_rows.positive?
        raise ArgumentError, "max_result_bytes must be positive" unless @max_result_bytes.positive?
        @mutex = Mutex.new
        @write_mutex = Mutex.new
        @handshake_mutex = Mutex.new
        @pending = {}
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thread = nil
        @reader_thread = nil
        @stderr_thread = nil
        @started = false
        @handshaken = false
        @stopping = false
        @worker_started_once = false
        @worker_starts = 0
        @worker_restarts = 0
        @worker_failures = 0
        @capabilities = []
        @performance_decisions = {}
        @performance_samples = Hash.new { |hash, key| hash[key] = {count: 0, fallbacks: 0, total_ms: 0.0, rows: 0} }
        @last_error = nil
      rescue ArgumentError, TypeError => error
        raise Error, "Invalid RubyDB accelerator configuration: #{error.message}"
      end

      def available?
        return false if @mode == "off"

        !@binary_path.nil? && File.file?(@binary_path)
      end

      def enabled?
        @mode != "off" && available?
      end

      def started?
        @mutex.synchronize { @started }
      end

      def stats
        @mutex.synchronize do
          {
            mode: @mode,
            available: available?,
            started: @started,
            binary_path: @binary_path,
            protocol_version: PROTOCOL_VERSION,
            capabilities: @capabilities.dup,
            performance_decisions: @performance_decisions.dup,
            performance_samples: @performance_samples.transform_values(&:dup),
            min_rows: @min_rows,
            max_rows: @max_rows,
            max_result_bytes: @max_result_bytes,
            read_pipeline: @read_pipeline,
            worker_pid: worker_pid,
            worker_starts: @worker_starts,
            worker_restarts: @worker_restarts,
            worker_failures: @worker_failures,
            last_error: @last_error
          }
        end
      end

      # Restart the private worker after an external failure. The next request
      # also starts a failed worker lazily, but this explicit operation is
      # useful to supervisors and release/soak tests that need to verify the
      # lifecycle independently of a query.
      def restart
        @mutex.synchronize do
          stop_locked
          @stopping = false
          start_locked
        end
        true
      end

      def request(type, payload = {}, timeout: @timeout)
        return nil if @mode == "off"
        return nil unless prepare_transport!
        ensure_handshake(timeout)
        exchange_json(type.to_s, payload, timeout)
      rescue Error
        raise
      rescue => error
        @last_error = "#{error.class}: #{error.message}"
        @mutex.synchronize { stop_locked }
        raise ProtocolError, "RubyDB accelerator communication failed: #{error.message}"
      end

      # Sends a bounded binary request over the same private stdio channel.
      # Large row batches avoid JSON and base64 conversion on both sides.
      def binary_request(type, payload, timeout: @timeout)
        return nil if @mode == "off"
        return nil unless prepare_transport!
        ensure_handshake(timeout)
        exchange_binary(type.to_s, payload, timeout)
      rescue Error
        raise
      rescue => error
        @last_error = "#{error.class}: #{error.message}"
        @mutex.synchronize { stop_locked }
        raise ProtocolError, "RubyDB accelerator communication failed: #{error.message}"
      end

      # Collects a sequence of bounded JSON result batches from the worker.
      # The worker may execute the request concurrently with other requests;
      # only this request's queue is consumed here.
      def request_stream(type, payload = {}, timeout: @timeout)
        return nil if @mode == "off"
        return nil unless prepare_transport!
        ensure_handshake(timeout)

        id = "acc_#{SecureRandom.hex(12)}"
        queue = register_pending(id)
        write_locked(message(type.to_s, payload, id))
        rows = []
        aggregates = nil
        Timeout.timeout(timeout, TimeoutError) do
          loop do
            response = queue.pop
            raise response if response.is_a?(Exception)
            unless response["success"] == true
              raise RequestError.new(response["error"].to_s, code: response["code"])
            end

            batch = response["payload"] || {}
            rows.concat(Array(batch["rows"]))
            aggregates = batch["aggregates"] if batch.key?("aggregates")
            break unless response["more"] == true
          end
        end
        {"rows" => rows, "row_count" => rows.length, "aggregates" => aggregates}
      rescue TimeoutError
        cancel_request(id, timeout)
        raise TimeoutError.new("RubyDB accelerator request timed out", code: "timeout")
      ensure
        @mutex.synchronize { @pending.delete(id) } if id
      end

      def supports?(capability)
        @mutex.synchronize { @capabilities.include?(capability.to_s) }
      end

      def performance_calibrated?(workload)
        @mutex.synchronize { @performance_decisions.key?(workload.to_sym) }
      end

      def acceleration_preferred?(workload)
        return true if @mode == "required"

        @mutex.synchronize { @performance_decisions.fetch(workload.to_sym, true) }
      end

      def record_performance(workload, ruby_ms:, go_ms:)
        return true if @mode == "required"

        preferred = go_ms < ruby_ms
        @mutex.synchronize { @performance_decisions[workload.to_sym] = preferred }
        preferred
      end

      def observe_performance(workload, milliseconds:, rows: 0, fallback: false)
        @mutex.synchronize do
          sample = @performance_samples[workload.to_sym]
          sample[:count] += 1
          sample[:fallbacks] += 1 if fallback
          sample[:total_ms] += Float(milliseconds)
          sample[:rows] += Integer(rows)
        end
      end

      def accelerator_policy(workload, input_rows:, estimated_bytes: 0, deadline_at: nil)
        return false if @mode == "off"
        return false unless supports?(workload_capability(workload))
        return false if input_rows && input_rows.to_i > @max_rows
        return false if estimated_bytes.to_i > @max_result_bytes
        return false if deadline_at && Time.now >= deadline_at

        acceleration_preferred?(workload)
      end

      def close
        @mutex.synchronize do
          if @started && @stdin && !@stdin.closed?
            begin
              write_locked(message("terminate"))
            rescue
              nil
            end
          end
          stop_locked
        end
        true
      end

      private

      def prepare_transport!
        return nil if @mode == "off"

        @mutex.synchronize do
          unless available?
            raise UnavailableError.new("RubyDB accelerator binary is not available", code: "binary_missing") if @mode == "required"

            return nil
          end
          start_locked
          true
        end
      end

      def workload_capability(workload)
        case workload.to_sym
        when :scan, :index_scan, :sort, :aggregate, :distinct, :window, :join, :merge_join
          "rows_pipeline"
        when :snapshot_scan
          "snapshot_scan"
        when :compression
          "gzip"
        when :checksum
          "sha256"
        when :wal_batch
          "wal_batch"
        else
          workload.to_s
        end
      end

      def validate_mode!
        return if %w[auto off required].include?(@mode)

        raise ArgumentError, "mode must be auto, off, or required"
      end

      def start_locked
        return if @started
        if @binary_path.nil? || !File.file?(@binary_path)
          raise UnavailableError.new("RubyDB accelerator binary is not available", code: "binary_missing")
        end
        verify_binary_integrity!

        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@binary_path)
        # The worker protocol carries both newline-delimited JSON and binary
        # frames. Ruby's Windows pipes default to text/UTF-8 behavior, which
        # rejects binary bytes such as a snapshot page header. Put every pipe
        # in binary mode before the reader or request threads can use it.
        @stdin.binmode
        @stdout.binmode
        @stderr.binmode
        @started = true
        @handshaken = false
        @stopping = false
        @worker_starts += 1
        @worker_restarts += 1 if @worker_started_once
        @worker_started_once = true
        stdout = @stdout
        @reader_thread = Thread.new { reader_loop(stdout) }
        stderr = @stderr
        @stderr_thread = Thread.new do
          stderr.each_line do |line|
            @last_error = line.to_s.strip unless line.to_s.strip.empty?
          end
        rescue IOError
          nil
        end
      rescue Errno::ENOENT => error
        @last_error = error.message
        stop_locked
        raise UnavailableError.new("Unable to start RubyDB accelerator: #{error.message}", code: "spawn_failed")
      end

      def ensure_handshake(timeout)
        @handshake_mutex.synchronize do
          return if @mutex.synchronize { @handshaken }

          response = exchange_json("handshake", {
            protocol_version: PROTOCOL_VERSION,
            client_name: "rubydb-ruby",
            client_version: (defined?(RubyDB::VERSION) ? RubyDB::VERSION : "unknown")
          }, timeout)
          unless response["protocol_version"].to_i == PROTOCOL_VERSION
            @mutex.synchronize { stop_locked }
            raise ProtocolError.new("RubyDB accelerator protocol handshake failed", code: "protocol_mismatch")
          end
          @mutex.synchronize do
            @capabilities = Array(response["capabilities"]).map(&:to_s)
            @handshaken = true
          end
        end
      end

      def exchange_json(type, payload, timeout)
        id = "acc_#{SecureRandom.hex(12)}"
        queue = register_pending(id)
        write_locked(message(type, payload, id))
        response = wait_for_pending(id, queue, timeout)
        unless response["success"] == true
          raise RequestError.new(response["error"].to_s, code: response["code"])
        end

        response["payload"] || {}
      rescue TimeoutError
        cancel_request(id, timeout)
        raise TimeoutError.new("RubyDB accelerator request timed out", code: "timeout")
      end

      def register_pending(id)
        queue = Queue.new
        @mutex.synchronize do
          raise ProtocolError.new("RubyDB accelerator is not running", code: "not_started") unless @started

          @pending[id] = queue
        end
        queue
      end

      def wait_for_pending(id, queue, timeout)
        value = Timeout.timeout(timeout, TimeoutError) { queue.pop }
        raise value if value.is_a?(Exception)

        value
      ensure
        @mutex.synchronize { @pending.delete(id) }
      end

      def cancel_request(target_id, timeout)
        return unless @mutex.synchronize { @started }

        cancel_id = "acc_cancel_#{SecureRandom.hex(8)}"
        queue = register_pending(cancel_id)
        write_locked(message("cancel", {target_id: target_id}, cancel_id))
        wait_for_pending(cancel_id, queue, [Float(timeout), 1.0].min)
      rescue Timeout::Error, TimeoutError, IOError, SystemCallError, ProtocolError
        @mutex.synchronize { stop_locked }
      end

      def write_locked(value)
        frame = "#{JSON.generate(value)}\n"
        raise ProtocolError.new("RubyDB accelerator request exceeds max frame size", code: "frame_too_large") if frame.bytesize > @max_frame_size

        @write_mutex.synchronize do
          @stdin.write(frame)
          @stdin.flush
        end
      end

      def exchange_binary(type, payload, timeout)
        type_id = case type
        when "rows_pipeline", "rows_pipeline_binary" then BINARY_ROWS_TYPE
        when "hash_join" then BINARY_JOIN_TYPE
        when "snapshot_scan" then BINARY_SNAPSHOT_SCAN_TYPE
        else
          raise RequestError.new("Unsupported binary accelerator operation", code: "unsupported_operation")
        end
        id = "acc_#{SecureRandom.hex(12)}"
        queue = register_pending(id)
        write_binary_locked(type_id, id, payload)
        result = wait_for_pending(id, queue, timeout)
        if result.is_a?(Hash) && result[:binary_error]
          error_payload = JSON.parse(result[:binary_error])
          raise RequestError.new(error_payload["error"].to_s, code: error_payload["code"])
        end
        result
      rescue TimeoutError
        cancel_request(id, timeout)
        raise TimeoutError.new("RubyDB accelerator request timed out", code: "timeout")
      end

      def write_binary_locked(type_id, id, payload)
        payload = payload.to_s.b
        if id.bytesize > 1024 || payload.bytesize > @max_frame_size || id.bytesize + payload.bytesize > @max_frame_size
          raise ProtocolError.new("RubyDB accelerator binary request exceeds max frame size", code: "frame_too_large")
        end
        header = [BINARY_MAGIC, BINARY_VERSION, 1, type_id, 0, id.bytesize, payload.bytesize].pack("a4C4vV")
        @write_mutex.synchronize do
          @stdin.write(header)
          @stdin.write(id)
          @stdin.write(payload)
          @stdin.flush
        end
      end

      def reader_loop(stdout)
        loop do
          prefix = stdout.read(4)
          raise EOFError if prefix.nil? || prefix.empty? || prefix.bytesize != 4

          if prefix == BINARY_MAGIC
            header = prefix + read_from_worker(stdout, 10)
            raise ProtocolError.new("Invalid binary response header", code: "invalid_response") unless header.getbyte(4) == BINARY_VERSION

            id_length = header.byteslice(8, 2).unpack1("v")
            payload_length = header.byteslice(10, 4).unpack1("V")
            raise ProtocolError.new("Binary response exceeds max frame size", code: "frame_too_large") if id_length > 1024 || payload_length > @max_frame_size || id_length + payload_length > @max_frame_size

            body = read_from_worker(stdout, id_length + payload_length)
            id = body.byteslice(0, id_length).to_s
            payload = body.byteslice(id_length, payload_length).to_s.b
            value = if header.getbyte(7) == 0
              payload
            else
              {binary_error: payload}
            end
            deliver_pending(id, value)
          else
            line = prefix + stdout.gets.to_s
            raise ProtocolError.new("Invalid JSON response", code: "invalid_response") if line.bytesize > @max_frame_size

            response = JSON.parse(line)
            deliver_pending(response["id"].to_s, response)
          end
        end
      rescue => error
        mark_worker_failure(error)
      end

      def mark_worker_failure(error)
        message = "#{error.class}: #{error.message}"
        streams = nil
        pending = []
        @mutex.synchronize do
          return if @stopping

          @last_error = message
          @worker_failures += 1
          @started = false
          @handshaken = false
          pending = @pending.values.dup
          @pending.clear
          streams = [@stdin, @stdout, @stderr]
          @stdin = @stdout = @stderr = nil
        end
        pending.each { |queue| queue << ProtocolError.new("RubyDB accelerator reader stopped: #{message}", code: "reader_stopped") }
        streams.each do |stream|
          stream.close unless stream.nil? || stream.closed?
        rescue IOError
          nil
        end
      end

      def read_from_worker(stdout, length)
        value = stdout.read(length)
        raise EOFError if value.nil? || value.bytesize != length

        value
      end

      def deliver_pending(id, value)
        queue = @mutex.synchronize { @pending[id] }
        queue << value if queue
      end

      def message(type, payload = {}, id = "acc_#{SecureRandom.hex(12)}")
        {"id" => id, "type" => type, "payload" => payload}
      end

      def stop_locked
        @stopping = true
        stdin = @stdin
        stdout = @stdout
        stderr = @stderr
        wait_thread = @wait_thread
        reader_thread = @reader_thread
        @stdin = @stdout = @stderr = @wait_thread = nil
        @reader_thread = nil
        @started = false
        @handshaken = false
        @capabilities = []

        pending = @pending.values.dup
        @pending.clear
        pending.each { |queue| queue << ProtocolError.new("RubyDB accelerator stopped", code: "stopped") }

        [stdin, stdout, stderr].each do |io|
          io&.close unless io.nil? || io.closed?
        rescue IOError
          nil
        end

        if wait_thread
          begin
            wait_thread.join(0.25)
            if wait_thread.alive?
              pid = wait_thread.respond_to?(:pid) ? wait_thread.pid : nil
              Process.kill("TERM", pid) if pid
              wait_thread.join(0.25)
            end
          rescue SystemCallError
            nil
          end
        end

        if reader_thread && reader_thread != Thread.current
          reader_thread.kill
          reader_thread.join(0.25)
        end

        @stderr_thread&.kill
        @stderr_thread = nil
      end

      def worker_pid
        return nil unless @wait_thread&.respond_to?(:pid)

        @wait_thread.pid
      rescue
        nil
      end

      def resolve_binary(configured)
        return File.expand_path(configured.to_s) unless configured.nil? || configured.to_s.empty?

        filename = "rubydb-accelerator-#{platform_name}"
        filename += ".exe" if windows?
        candidates = [
          File.join(__dir__, "bin", filename),
          File.expand_path(File.join(__dir__, "..", "..", "..", "accelerator", "bin", filename)),
          File.expand_path(File.join(Dir.pwd, "accelerator", "bin", filename))
        ]
        candidates.find { |path| File.file?(path) }
      end

      def verify_binary_integrity!
        manifest = File.join(File.dirname(@binary_path), "SHA256SUMS")
        return unless File.file?(manifest)

        entry = File.readlines(manifest, chomp: true).find do |line|
          digest, name = line.split(/\s+/, 2)
          name == File.basename(@binary_path) && digest && digest.match?(/\A[0-9a-f]{64}\z/i)
        end
        raise UnavailableError.new("RubyDB accelerator binary is not listed in SHA256SUMS", code: "binary_checksum_missing") unless entry

        expected = entry.split(/\s+/, 2).first.downcase
        actual = Digest::SHA256.file(@binary_path).hexdigest
        return if expected == actual

        raise UnavailableError.new("RubyDB accelerator binary checksum mismatch", code: "binary_checksum_mismatch")
      end

      def windows?
        RbConfig::CONFIG["host_os"].to_s.match?(/mswin|mingw|cygwin/i)
      end

      def platform_name
        os = if windows?
          "windows"
        elsif RbConfig::CONFIG["host_os"].to_s.match?(/darwin/i)
          "darwin"
        else
          "linux"
        end
        cpu = RbConfig::CONFIG["host_cpu"].to_s
        arch = case cpu
        when /aarch64|arm64/ then "arm64"
        when /386|i.86/ then "386"
        else "amd64"
        end
        "#{os}-#{arch}"
      end
    end
  end
end
