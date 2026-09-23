# frozen_string_literal: true

require "base64"
require "bigdecimal"
require "date"
require "json"
require "time"

module RubyDB
  module Accelerator
    # High-level operations that are safe to delegate. The methods return nil
    # in auto mode when no compatible binary is installed, allowing callers to
    # execute the existing Ruby path without changing semantics.
    class Client
      attr_reader :manager

      def initialize(config = {})
        @manager = Manager.new(config || {})
      end

      def available?
        @manager.available?
      end

      def enabled?
        @manager.enabled?
      end

      def min_rows
        @manager.min_rows
      end

      def min_rows_for(workload)
        @manager.min_rows_for(workload)
      end

      def preferred_for?(workload, input_rows:, estimated_bytes: 0, deadline_at: nil)
        @manager.accelerator_policy(
          workload,
          input_rows: input_rows,
          estimated_bytes: estimated_bytes,
          deadline_at: deadline_at
        )
      end

      def read_pipeline?
        return false if @manager.mode == "off"
        return true if @manager.mode == "required"

        @manager.read_pipeline == "on" && @manager.available?
      end

      def stats
        @manager.stats
      end

      def restart
        @manager.restart
      end

      def ping
        @manager.request("ping")
      end

      # Runtime timings are collected by the long-lived Go process. Exposing
      # them makes the metrics package operational rather than dead code and
      # lets deployments verify the worker is serving real requests.
      def worker_metrics
        @manager.request("stats") || {}
      end

      def sha256(data)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        payload = @manager.request("sha256", {data_base64: Base64.strict_encode64(data.to_s.b)})
        @manager.observe_performance(:checksum, milliseconds: elapsed_ms(started), rows: data.to_s.bytesize)
        payload&.fetch("digest")
      end

      def gzip(data, level: nil)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        options = {data_base64: Base64.strict_encode64(data.to_s.b)}
        options[:level] = level if level
        payload = @manager.request("gzip", options)
        @manager.observe_performance(:compression, milliseconds: elapsed_ms(started), rows: data.to_s.bytesize)
        payload && Base64.strict_decode64(payload.fetch("data_base64"))
      end

      def gunzip(data)
        payload = @manager.request("gunzip", {data_base64: Base64.strict_encode64(data.to_s.b)})
        payload && Base64.strict_decode64(payload.fetch("data_base64"))
      end

      def rows_pipeline(rows, filters: [], order_by: [], group_by: [], aggregates: [], having: [],
        projection: [], distinct: false, distinct_columns: [], windows: [], batch_size: nil, limit: nil, offset: 0)
        if rows.length > @manager.max_rows
          raise Error.new("accelerator row limit exceeded", code: "resource_limit") if @manager.mode == "required"

          return nil
        end
        if read_pipeline? && binary_rows_safe?(rows)
          return binary_rows_pipeline(rows, filters: filters, order_by: order_by, group_by: group_by,
            aggregates: aggregates, having: having, projection: projection, distinct: distinct,
            distinct_columns: distinct_columns, windows: windows, batch_size: batch_size,
            limit: limit, offset: offset)
        end

        json_rows_pipeline(rows, filters: filters, order_by: order_by, group_by: group_by,
          aggregates: aggregates, having: having, projection: projection, distinct: distinct,
          distinct_columns: distinct_columns, windows: windows, batch_size: batch_size,
          limit: limit, offset: offset)
      rescue RubyDB::Accelerator::Error
        raise if @manager.mode == "required"

        json_rows_pipeline(rows, filters: filters, order_by: order_by, group_by: group_by,
          aggregates: aggregates, limit: limit, offset: offset)
      end

      def binary_rows_pipeline(rows, filters:, order_by:, group_by:, aggregates:, having:, projection:, distinct:, distinct_columns:, windows:, batch_size:, limit:, offset:)
        specification = JSON.generate(
          filters: filters,
          order_by: order_by,
          group_by: group_by,
          aggregates: aggregates,
          having: having,
          projection: projection,
          distinct: distinct,
          distinct_columns: distinct_columns,
          windows: windows,
          batch_size: batch_size,
          offset: offset,
          limit: limit
        )
        payload = [specification.bytesize].pack("V") + specification.b + encode_columnar_rows(rows)
        response = @manager.binary_request("rows_pipeline", payload)
        decode_binary_result(response)
      end

      def json_rows_pipeline(rows, filters:, order_by:, group_by:, aggregates:, having:, projection:, distinct:, distinct_columns:, windows:, batch_size:, limit:, offset:)
        payload = {
          rows: rows,
          filters: filters,
          order_by: order_by,
          group_by: group_by,
          aggregates: aggregates,
          having: having,
          projection: projection,
          distinct: distinct,
          distinct_columns: distinct_columns,
          windows: windows,
          batch_size: batch_size,
          offset: offset
        }
        payload[:limit] = limit unless limit.nil?
        response = @manager.request("rows_pipeline", payload)
        response&.transform_keys(&:to_sym)
      end

      def rows_pipeline_stream(rows, filters: [], order_by: [], group_by: [], aggregates: [], having: [],
        projection: [], distinct: false, distinct_columns: [], windows: [], batch_size: 1024, limit: nil, offset: 0)
        if rows.length > @manager.max_rows
          raise Error.new("accelerator row limit exceeded", code: "resource_limit") if @manager.mode == "required"

          return nil
        end
        payload = {
          rows: rows,
          filters: filters,
          order_by: order_by,
          group_by: group_by,
          aggregates: aggregates,
          having: having,
          projection: projection,
          distinct: distinct,
          distinct_columns: distinct_columns,
          windows: windows,
          batch_size: batch_size,
          offset: offset
        }
        payload[:limit] = limit unless limit.nil?
        @manager.request_stream("rows_pipeline_stream", payload)&.transform_keys(&:to_sym)
      rescue RubyDB::Accelerator::Error
        raise if @manager.mode == "required"

        nil
      end

      def wal_batch(records, compress: false)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        payload = {
          records: Array(records).map do |record|
            record = record.transform_keys(&:to_sym)
            {
              kind: Integer(record.fetch(:kind)),
              lsn: Integer(record.fetch(:lsn)),
              transaction: Integer(record.fetch(:transaction, 0)),
              payload_base64: Base64.strict_encode64(record.fetch(:payload).to_s.b)
            }
          end,
          compress: compress
        }
        result = @manager.request("wal_batch", payload)
        @manager.observe_performance(:wal_batch, milliseconds: elapsed_ms(started), rows: records.length)
        result&.transform_keys(&:to_sym)
      rescue KeyError, TypeError, ArgumentError => error
        raise Error, "Invalid WAL batch: #{error.message}"
      end

      def hash_join(left_rows, right_rows, left_key:, right_key:, join_type: "inner")
        return nil unless read_pipeline? && binary_rows_safe?(left_rows) && binary_rows_safe?(right_rows)

        specification = JSON.generate(left_key: left_key.to_s, right_key: right_key.to_s, join_type: join_type.to_s, algorithm: "hash")
        left_batch = encode_columnar_rows(left_rows)
        right_batch = encode_columnar_rows(right_rows)
        payload = [specification.bytesize].pack("V") + specification.b +
          [left_batch.bytesize].pack("V") + left_batch +
          [right_batch.bytesize].pack("V") + right_batch
        decode_binary_result(@manager.binary_request("hash_join", payload))
      rescue RubyDB::Accelerator::Error
        raise if @manager.mode == "required"

        nil
      end

      def merge_join(left_rows, right_rows, left_key:, right_key:, join_type: "inner")
        return nil unless read_pipeline? && binary_rows_safe?(left_rows) && binary_rows_safe?(right_rows)
        return nil if left_rows.length + right_rows.length > @manager.max_rows

        specification = JSON.generate(left_key: left_key.to_s, right_key: right_key.to_s,
          join_type: join_type.to_s, algorithm: "merge")
        left_batch = encode_columnar_rows(left_rows)
        right_batch = encode_columnar_rows(right_rows)
        payload = [specification.bytesize].pack("V") + specification.b +
          [left_batch.bytesize].pack("V") + left_batch +
          [right_batch.bytesize].pack("V") + right_batch
        decode_binary_result(@manager.binary_request("hash_join", payload))
      rescue RubyDB::Accelerator::Error
        raise if @manager.mode == "required"

        nil
      end

      # Scan an immutable storage snapshot. The request contains no Ruby row
      # hashes; Go opens the snapshot file, decodes pages, applies predicates,
      # and returns a bounded columnar result.
      def snapshot_scan(manifest, table:, columns:, column_types:, filters: [], order_by: [], index_name: nil,
        distinct: false, distinct_columns: [], limit: nil, offset: 0, batch_size: nil)
        return nil unless read_pipeline?

        specification = {
          snapshot: manifest,
          table: table.to_s,
          columns: Array(columns).map(&:to_s),
          column_types: column_types.transform_keys(&:to_s).transform_values(&:to_s),
          filters: filters,
          order_by: order_by,
          distinct: distinct,
          distinct_columns: distinct_columns,
          limit: limit,
          offset: offset,
          batch_size: batch_size,
          max_rows: @manager.max_rows
        }
        specification[:index_name] = index_name.to_s if index_name
        response = @manager.binary_request("snapshot_scan", JSON.generate(specification))
        decode_binary_result(response, column_types: column_types)
      rescue RubyDB::Accelerator::Error
        raise if @manager.mode == "required"

        nil
      end

      def binary_rows_safe?(rows)
        rows.all? do |row|
          row.all? { |_key, value| binary_value_safe?(value) }
        end
      end

      def binary_value_safe?(value)
        case value
        when NilClass, TrueClass, FalseClass, String, Array, Hash
          if value.is_a?(Array)
            value.all? { |item| binary_value_safe?(item) }
          elsif value.is_a?(Hash)
            value.all? { |key, item| (key.is_a?(String) || key.is_a?(Symbol)) && binary_value_safe?(item) }
          else
            true
          end
        when Integer
          value >= -(1 << 63) && value <= ((1 << 63) - 1)
        when Float
          value.finite?
        else
          false
        end
      end

      def encode_columnar_rows(rows)
        columns = []
        seen = {}
        rows.each do |row|
          row.each_key do |key|
            name = key.to_s
            next if seen[name]

            seen[name] = true
            columns << name
          end
        end
        output = [columns.length, rows.length].pack("vV")
        columns.each do |column|
          bytes = column.b
          raise Error, "RubyDB accelerator column name is too long" if bytes.bytesize > 65_535

          output << [bytes.bytesize].pack("v") << bytes
        end
        columns.each do |column|
          rows.each do |row|
            value = if row.key?(column)
              row[column]
            elsif row.key?(column.to_sym)
              row[column.to_sym]
            end
            output << encode_binary_value(value)
          end
        end
        output
      end

      def encode_binary_value(value)
        case value
        when nil
          [0].pack("C")
        when true, false
          [1, value ? 1 : 0].pack("C2")
        when Integer
          [2].pack("C") + [value].pack("q<")
        when Float
          [3].pack("C") + [value].pack("E")
        when String
          bytes = value.b
          [4].pack("C") + [bytes.bytesize].pack("V") + bytes
        when Array, Hash
          encoded = JSON.generate(value)
          [6].pack("C") + [encoded.bytesize].pack("V") + encoded.b
        else
          raise Error, "RubyDB accelerator cannot encode #{value.class} in a binary row batch"
        end
      end

      def decode_binary_result(data, column_types: nil)
        offset = 0
        metadata_length = read_uint32(data, offset)
        offset += 4
        metadata = JSON.parse(data.byteslice(offset, metadata_length))
        offset += metadata_length
        row_length = read_uint32(data, offset)
        offset += 4
        rows = decode_columnar_rows(data.byteslice(offset, row_length))
        rows = restore_snapshot_types(rows, column_types || metadata["column_types"])
        offset += row_length
        aggregate_length = read_uint32(data, offset)
        offset += 4
        aggregates = decode_columnar_rows(data.byteslice(offset, aggregate_length))
        {
          rows: rows,
          row_count: metadata.fetch("row_count", rows.length),
          aggregates: metadata["has_aggregates"] ? aggregates : nil
        }
      rescue JSON::ParserError, TypeError, ArgumentError, RangeError => error
        raise ProtocolError.new("Invalid RubyDB accelerator binary result: #{error.message}", code: "invalid_response")
      end

      def restore_snapshot_types(rows, column_types)
        return rows unless column_types.is_a?(Hash) && !column_types.empty?

        rows.map do |row|
          row.each_with_object({}) do |(column, value), restored|
            type = column_types[column] || column_types[column.to_sym]
            restored[column] = restore_snapshot_value(value, type)
          end
        end
      end

      def restore_snapshot_value(value, type)
        return value if value.nil? || type.nil?

        case type.to_s.downcase
        when "date"
          Date.parse(value.to_s)
        when "time", "timestamp"
          Time.parse(value.to_s)
        when "decimal"
          BigDecimal(value.to_s)
        when "json"
          value.is_a?(String) ? JSON.parse(value) : value
        else
          value
        end
      rescue ArgumentError, TypeError, JSON::ParserError
        value
      end

      def decode_columnar_rows(data)
        offset = 0
        column_count = read_uint16(data, offset)
        offset += 2
        row_count = read_uint32(data, offset)
        offset += 4
        columns = column_count.times.map do
          length = read_uint16(data, offset)
          offset += 2
          value = data.byteslice(offset, length).to_s
          offset += length
          value
        end
        rows = Array.new(row_count) { {} }
        columns.each do |column|
          row_count.times do |index|
            value, consumed = decode_binary_value(data, offset)
            offset += consumed
            rows[index][column] = value
          end
        end
        raise ProtocolError.new("Binary row batch has trailing bytes", code: "invalid_response") unless offset == data.bytesize

        rows
      end

      def decode_binary_value(data, offset)
        tag = data.getbyte(offset)
        raise RangeError, "missing binary value tag" unless tag

        case tag
        when 0 then [nil, 1]
        when 1 then [data.getbyte(offset + 1) == 1, 2]
        when 2 then [data.byteslice(offset + 1, 8).unpack1("q<"), 9]
        when 3 then [data.byteslice(offset + 1, 8).unpack1("E"), 9]
        when 4
          length = data.byteslice(offset + 1, 4).unpack1("V")
          [data.byteslice(offset + 5, length).to_s.force_encoding(Encoding::UTF_8), 5 + length]
        when 5
          length = data.byteslice(offset + 1, 4).unpack1("V")
          [data.byteslice(offset + 5, length).to_s.b, 5 + length]
        when 6
          length = data.byteslice(offset + 1, 4).unpack1("V")
          [JSON.parse(data.byteslice(offset + 5, length)), 5 + length]
        else
          raise RangeError, "unknown binary value tag #{tag}"
        end
      end

      def read_uint16(data, offset)
        data.byteslice(offset, 2).unpack1("v")
      end

      def read_uint32(data, offset)
        data.byteslice(offset, 4).unpack1("V")
      end

      def close
        @manager.close
      end

      private

      def elapsed_ms(started)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
      end
    end
  end
end
