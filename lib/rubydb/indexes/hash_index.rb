# frozen_string_literal: true

require "monitor"

module RubyDB
  module Indexes
    # Hash index implementation (for exact equality lookups)
    class HashIndex < Index
      def initialize(name, table_name, columns, options = {})
        super(name, table_name, columns, options)
        @hash_table = {}
        @bucket_count = options[:bucket_count] || 1024
        @max_load_factor = options[:max_load_factor] || 0.75
        @lock = Monitor.new
        @is_built = false
      end

      def insert(key, row_id)
        @lock.synchronize do
          hash_key = hash_key(key)
          @hash_table[hash_key] ||= []
          
          # Check for duplicates if unique
          if @unique
            existing = @hash_table[hash_key].find { |entry| entry[:key] == key && entry[:row_id] == row_id }
            return false if existing
          end
          
          @hash_table[hash_key] << { key: key, row_id: row_id }
          @entries_count += 1
          @modified_at = Time.now
          
          # Rehash if load factor exceeded
          rehash if load_factor > @max_load_factor
          
          true
        end
      end

      def delete(key, row_id)
        @lock.synchronize do
          hash_key = hash_key(key)
          bucket = @hash_table[hash_key]
          return false unless bucket
          
          bucket.delete_if { |entry| entry[:key] == key && entry[:row_id] == row_id }
          @hash_table.delete(hash_key) if bucket.empty?
          @entries_count -= 1
          @modified_at = Time.now
          true
        end
      end

      def search(key)
        @lock.synchronize do
          hash_key = hash_key(key)
          bucket = @hash_table[hash_key]
          return [] unless bucket
          
          bucket.select { |entry| entry[:key] == key }.map { |entry| entry[:row_id] }
        end
      end

      def range_search(start_key, end_key)
        # Hash index doesn't support efficient range queries
        # Return all entries in the range (slow)
        @lock.synchronize do
          results = []
          @hash_table.each do |_, bucket|
            bucket.each do |entry|
              if entry[:key] >= start_key && entry[:key] <= end_key
                results << entry
              end
            end
          end
          results
        end
      end

      def build(rows)
        @lock.synchronize do
          clear
          
          rows.each do |row|
            key = extract_key(row)
            row_id = row[:_row_id] || row["id"] || row[:id]
            insert(key, row_id)
          end
          
          @is_built = true
          @modified_at = Time.now
          true
        end
      end

      def clear
        @lock.synchronize do
          @hash_table.clear
          @entries_count = 0
          @is_built = false
          true
        end
      end

      def analyze
        super.merge({
          bucket_count: @bucket_count,
          load_factor: load_factor,
          max_load_factor: @max_load_factor,
          is_built: @is_built
        })
      end

      private

      def hash_key(key)
        key_hash = key.is_a?(Array) ? key.hash : key.hash
        key_hash.abs % @bucket_count
      end

      def extract_key(row)
        if @columns.size == 1
          column = @columns.first
          row.key?(column) ? row[column] : row[column.to_s]
        else
          @columns.map { |col| row.key?(col) ? row[col] : row[col.to_s] }
        end
      end

      def load_factor
        @entries_count.to_f / @bucket_count
      end

      def rehash
        new_bucket_count = @bucket_count * 2
        old_table = @hash_table
        @hash_table = {}
        @bucket_count = new_bucket_count
        
        old_table.each do |_, bucket|
          bucket.each do |entry|
            hash_key = hash_key(entry[:key])
            @hash_table[hash_key] ||= []
            @hash_table[hash_key] << entry
          end
        end
      end
    end
  end
end
