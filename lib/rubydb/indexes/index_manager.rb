# frozen_string_literal: true

module RubyDB
  module Indexes
    # IndexManager - Manages all indexes for the database
    class IndexManager
      attr_reader :indexes, :stats

      def initialize(engine)
        @engine = engine
        @indexes = {}
        @table_indexes = {}
        @stats = {
          index_creates: 0,
          index_drops: 0,
          index_builds: 0,
          index_searches: 0,
          index_inserts: 0,
          index_deletes: 0,
          cache_hits: 0,
          cache_misses: 0
        }
        @cache = {}
        @cache_size = 100
        @lock = Mutex.new
        
        load_indexes
      end

      def create_index(name, table_name, columns, options = {})
        @lock.synchronize do
          # Check if index already exists
          if @indexes.key?(name)
            raise DatabaseError, "Index '#{name}' already exists" unless options[:if_not_exists]
            return false
          end
          
          # Check if table exists
          unless @engine.table_exists?(table_name)
            raise DatabaseError, "Table '#{table_name}' does not exist"
          end
          
          # Create index based on type
          index_type = options[:type] || :btree
          index = case index_type
          when :btree
            BTree.new(name, table_name, columns, options)
          when :hash
            HashIndex.new(name, table_name, columns, options)
          else
            raise ConfigurationError, "Unsupported index type: #{index_type}"
          end
          
          # Store index
          @indexes[name] = index
          @table_indexes[table_name] ||= []
          @table_indexes[table_name] << name
          
          # Build index from existing data
          build_index(name) unless options[:skip_build]
          
          @stats[:index_creates] += 1
          save_indexes
          
          true
        end
      end

      def drop_index(name, options = {})
        @lock.synchronize do
          unless @indexes.key?(name)
            return false if options[:if_exists]
            raise DatabaseError, "Index '#{name}' does not exist"
          end
          
          index = @indexes[name]
          table_name = index.table_name
          
          # Remove from table index list
          if @table_indexes[table_name]
            @table_indexes[table_name].delete(name)
            @table_indexes.delete(table_name) if @table_indexes[table_name].empty?
          end
          
          # Clear index
          index.clear
          
          # Remove from cache
          @cache.delete(name)
          
          @indexes.delete(name)
          @stats[:index_drops] += 1
          save_indexes
          
          true
        end
      end

      def get_index(name)
        @lock.synchronize do
          @indexes[name]
        end
      end

      def get_indexes_for_table(table_name)
        @lock.synchronize do
          (@table_indexes[table_name] || []).map { |name| @indexes[name] }.compact
        end
      end

      def index_exists?(name)
        @indexes.key?(name)
      end

      def build_index(name)
        @lock.synchronize do
          index = @indexes[name]
          return false unless index
          
          # Get all rows from table
          columns = @engine.table_columns(index.table_name)
          rows = @engine.select_rows(index.table_name, columns)
          
          # Build index
          index.build(rows)
          
          @stats[:index_builds] += 1
          save_indexes
          true
        end
      end

      def rebuild_index(name)
        @lock.synchronize do
          drop_index(name, if_exists: true)
          create_index(name, @indexes[name].table_name, @indexes[name].columns, @indexes[name].options)
          true
        end
      end

      def rebuild_all_indexes
        @lock.synchronize do
          @indexes.keys.each do |name|
            rebuild_index(name)
          end
          true
        end
      end

      def insert_row(table_name, row)
        @lock.synchronize do
          indexes = get_indexes_for_table(table_name)
          return unless indexes.any?
          
          indexes.each do |index|
            key = extract_key(row, index.columns)
            row_id = row[:_row_id] || row["id"] || row[:id]
            index.insert(key, row_id)
            @stats[:index_inserts] += 1
          end
        end
      end

      def delete_row(table_name, row)
        @lock.synchronize do
          indexes = get_indexes_for_table(table_name)
          return unless indexes.any?
          
          indexes.each do |index|
            key = extract_key(row, index.columns)
            row_id = row[:_row_id] || row["id"] || row[:id]
            index.delete(key, row_id)
            @stats[:index_deletes] += 1
          end
        end
      end

      def update_row(table_name, old_row, new_row)
        @lock.synchronize do
          indexes = get_indexes_for_table(table_name)
          return unless indexes.any?
          
          indexes.each do |index|
            old_key = extract_key(old_row, index.columns)
            new_key = extract_key(new_row, index.columns)
            row_id = new_row[:_row_id] || new_row["id"] || new_row[:id]
            
            if old_key != new_key
              # Update index
              index.delete(old_key, row_id)
              index.insert(new_key, row_id)
            end
          end
        end
      end

      def find_index_for_query(table_name, conditions)
        @lock.synchronize do
          indexes = get_indexes_for_table(table_name)
          return nil if indexes.empty?
          
          # Try to find the best index for the query
          indexes.each do |index|
            # Check if all columns in condition are in index
            index_columns = index.columns
            condition_keys = conditions.keys.map(&:to_s)
            
            if index_columns.all? { |col| condition_keys.include?(col.to_s) }
              # Check if the condition has an operator that can use the index
              if index.type == :hash
                # Hash index works best for equality
                return index if conditions.values.all? { |v| v[:operator] == :eq }
              elsif index.type == :btree
                # B-Tree works for equality, range, and prefix
                return index
              end
            end
          end
          
          # Return first index if no better match
          indexes.first
        end
      end

      def analyze_index(name)
        @lock.synchronize do
          index = @indexes[name]
          return nil unless index
          index.analyze
        end
      end

      def analyze_all_indexes
        @lock.synchronize do
          @indexes.transform_values(&:analyze)
        end
      end

      def stats
        @lock.synchronize do
          {
            total_indexes: @indexes.size,
            index_creates: @stats[:index_creates],
            index_drops: @stats[:index_drops],
            index_builds: @stats[:index_builds],
            index_searches: @stats[:index_searches],
            index_inserts: @stats[:index_inserts],
            index_deletes: @stats[:index_deletes],
            cache_hits: @stats[:cache_hits],
            cache_misses: @stats[:cache_misses],
            cache_hit_rate: cache_hit_rate,
            by_type: index_count_by_type
          }
        end
      end

      private

      def extract_key(row, columns)
        if columns.size == 1
          row[columns.first]
        else
          columns.map { |col| row[col] }
        end
      end

      def index_count_by_type
        counts = Hash.new(0)
        @indexes.each do |_, index|
          counts[index.type] += 1
        end
        counts
      end

      def cache_hit_rate
        total = @stats[:cache_hits] + @stats[:cache_misses]
        return 0.0 if total == 0
        (@stats[:cache_hits].to_f / total * 100).round(2)
      end

      def load_indexes
        @lock.synchronize do
          begin
            index_path = index_metadata_path
            if File.exist?(index_path)
              data = File.read(index_path)
              parsed = JSON.parse(data, symbolize_names: true)
              
              parsed[:indexes]&.each do |name, index_data|
                # Recreate index from metadata
                # This would need to load the actual index data
                # Simplified for now
              end
            end
          rescue => e
            # Start fresh
            @indexes.clear
            @table_indexes.clear
          end
        end
      end

      def save_indexes
        @lock.synchronize do
          begin
            data = {
              indexes: {},
              timestamp: Time.now.iso8601
            }
            
            @indexes.each do |name, index|
              data[:indexes][name] = {
                table_name: index.table_name,
                columns: index.columns,
                type: index.type,
                unique: index.unique,
                options: index.options,
                entries: index.entries_count,
                created_at: index.instance_variable_get(:@created_at).iso8601
              }
            end
            
            File.write(index_metadata_path, JSON.generate(data))
          rescue => e
            # Log error but continue
          end
        end
      end

      def index_metadata_path
        "#{@engine.instance_variable_get(:@path)}.indexes"
      end
    end
  end
end