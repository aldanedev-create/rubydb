# frozen_string_literal: true


# Standard library
require "json"
require "set"
require "fileutils"

# Storage components
require_relative "storage_manager"
require_relative "page"
require_relative "page_header"
require_relative "record"
require_relative "row"
require_relative "tuple"
require_relative "serializer"
require_relative "deserializer"
require_relative "visibility_map"
require_relative "storage_layout"

# Catalog components
require_relative "../catalog/catalog"
require_relative "../catalog/table"
require_relative "../catalog/column"

# Types
require_relative "../types/type"
require_relative "../types/type_registry"

# Errors
require_relative "../errors/storage_error"
require_relative "../errors/database_error"
require_relative "../errors/corruption_error"

require "json"
require "set"

module RubyDB
  module Storage
    # Engine - Main storage engine interface with full CRUD operations
    class Engine
      attr_reader :storage_manager, :buffer_pool, :page_manager, :catalog
      attr_reader :table_metadata, :transaction_manager

      def initialize(path, config = {})
        @path = path
        @config = config
        @catalog = config[:catalog] || Catalog::Catalog.new
        @storage_manager = StorageManager.new(path, config)
        @storage_manager.open

        @buffer_pool = @storage_manager.buffer_pool
        @page_manager = @storage_manager.page_manager
        @page_allocator = @storage_manager.page_allocator
        @visibility_map = VisibilityMap.new(@page_manager, config)
        @table_metadata = {}
        @table_pages = {}
        @row_cache = {}
        @cache_size = config[:cache_size] || 1000
        @cache_ttl = config[:cache_ttl] || 300  # 5 minutes
        @is_open = true
        @transaction_manager = nil
        @stats = {
          table_creates: 0,
          row_inserts: 0,
          row_selects: 0,
          row_updates: 0,
          row_deletes: 0,
          cache_hits: 0,
          cache_misses: 0,
          transaction_begin: 0,
          transaction_commit: 0,
          transaction_rollback: 0
        }
        @lock = Mutex.new
        
        # Load table metadata from disk
        load_table_metadata
        
        # Start cleanup thread if configured
        start_cleanup_thread if config[:auto_cleanup] != false
      end

      # Page operations
      def read_page(page_number)
        @storage_manager.read_page(page_number)
      end

      def write_page(page)
        @storage_manager.write_page(page)
      end

      def allocate_page(page_type = 0)
        @storage_manager.allocate_page(page_type)
      end

      def free_page(page_number)
        @storage_manager.free_page(page_number)
      end

      # Record operations
      def read_record(page_number, offset, length)
        @storage_manager.read_record(page_number, offset, length)
      end

      def write_record(page_number, offset, data)
        @storage_manager.write_record(page_number, offset, data)
      end

      # Table operations
      def create_table(table_name, columns, options = {})
        @lock.synchronize do
          @stats[:table_creates] += 1
          
          # Check if table already exists
          if @table_metadata.key?(table_name)
            raise DatabaseError, "Table '#{table_name}' already exists" unless options[:if_not_exists]
            return false
          end
          
          # Allocate pages for the table
          data_page = allocate_page(StorageLayout::PAGE_TYPE_TABLE)
          metadata_page = allocate_page(StorageLayout::PAGE_TYPE_TABLE)
          
          # Create table metadata
          metadata = StorageLayout::TableMetadata.new
          metadata.table_id = metadata_page
          metadata.table_name = table_name
          metadata.column_count = columns.size
          metadata.row_count = 0
          metadata.first_page = data_page
          metadata.last_page = data_page
          metadata.created_at = Time.now.to_i
          metadata.updated_at = Time.now.to_i
          
          # Write metadata
          page = Page.new(metadata_page, @storage_manager.page_size)
          page.write(0, metadata.serialize)
          write_page(page)
          
          # Write column metadata
          columns.each_with_index do |col, idx|
            col_meta = StorageLayout::ColumnMetadata.new
            col_meta.column_id = idx + 1
            col_meta.column_name = col.name
            col_meta.data_type = col.type_class
            col_meta.is_nullable = col.nullable?
            col_meta.is_primary_key = col.primary_key?
            col_meta.position = idx
            col_meta.default = col.default if col.has_default?
            col_meta.created_at = Time.now.to_i
            
            page.write(PageHeader::SIZE + idx * 128, col_meta.serialize)
          end
          write_page(page)
          
          # Initialize data page
          data_page_obj = Page.new(data_page, @storage_manager.page_size)
          data_page_obj.header.page_type = StorageLayout::PAGE_TYPE_TABLE
          data_page_obj.header.data_end = PageHeader::SIZE
          data_page_obj.write_header
          write_page(data_page_obj)
          
          # Store metadata
          @table_metadata[table_name] = {
            metadata_page: metadata_page,
            data_page: data_page,
            columns: columns,
            column_count: columns.size,
            row_count: 0,
            created_at: Time.now,
            updated_at: Time.now
          }
          
          @table_pages[table_name] = [data_page]
          
          # Add to catalog
          @catalog.create_table(table_name) do |t|
            columns.each do |col|
              t.column(col.name, col.type_class, col.options)
            end
          end if @catalog && @catalog.current_database
          
          # Save metadata to disk
          save_table_metadata
          
          true
        end
      end

      def drop_table(table_name, options = {})
        @lock.synchronize do
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          
          # Free all pages for this table
          pages = @table_pages[table_name] || []
          pages.each do |page_number|
            free_page(page_number)
          end
          
          # Free metadata page
          free_page(metadata[:metadata_page])
          
          # Remove from metadata
          @table_metadata.delete(table_name)
          @table_pages.delete(table_name)
          
          # Remove from catalog
          @catalog.drop_table(table_name) if @catalog && @catalog.current_database
          
          # Save metadata to disk
          save_table_metadata
          
          true
        end
      end

      def table_exists?(table_name)
        @table_metadata.key?(table_name)
      end

      def list_tables
        @table_metadata.keys
      end

      def table_columns(table_name)
        metadata = @table_metadata[table_name]
        return [] unless metadata
        metadata[:columns]
      end

      def table_row_count(table_name)
        metadata = @table_metadata[table_name]
        return 0 unless metadata
        metadata[:row_count] || 0
      end

      # Row operations
      def insert_row(table_name, columns, values)
        @lock.synchronize do
          @stats[:row_inserts] += 1
          
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          
          # Get the last data page or allocate new one
          data_page = get_or_allocate_data_page(table_name)
          page = read_page(data_page)
          
          # Create row
          row_id = metadata[:row_count] + 1
          row = Row.new(row_id, columns, values)
          
          # Serialize row data
          row_data = Serializer.serialize_row(row, columns)
          
          # Calculate required space (row header + data)
          required_space = 16 + row_data.bytesize  # 16 bytes for row header
          
          # Check if we have enough space on the page
          if page.free_space < required_space
            # Allocate new page
            new_page_num = allocate_page(StorageLayout::PAGE_TYPE_TABLE)
            new_page = Page.new(new_page_num, @storage_manager.page_size)
            new_page.header.page_type = StorageLayout::PAGE_TYPE_TABLE
            new_page.header.data_end = PageHeader::SIZE
            new_page.write_header
            write_page(new_page)
            
            @table_pages[table_name] << new_page_num
            metadata[:last_page] = new_page_num
            
            page = new_page
            data_page = new_page_num
          end
          
          # Write record
          offset = page.header.data_end
          record_id = row_id
          record_size = row_data.bytesize
          flags = 0
          column_count = columns.size
          
          # Write record header: record_id(8) + record_size(4) + flags(2) + column_count(2)
          page.write(offset, [record_id, record_size, flags, column_count].pack("Q>L>S>S"))
          offset += 16
          
          # Write record data
          page.write(offset, row_data)
          offset += record_size
          
          # Update page header
          page.header.data_end = offset
          page.write_header
          write_page(page)
          
          # Update metadata
          metadata[:row_count] += 1
          metadata[:updated_at] = Time.now
          
          # Update catalog
          if @catalog && @catalog.current_database
            table = @catalog.find_table(table_name)
            table.row_count = metadata[:row_count] if table
          end
          
          # Save metadata
          save_table_metadata
          
          # Invalidate cache
          invalidate_cache(table_name, row_id)
          
          row_id
        end
      end

      def select_rows(table_name, columns, conditions = {})
        @lock.synchronize do
          @stats[:row_selects] += 1
          
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          
          # Get all data pages for the table
          pages = @table_pages[table_name] || []
          return [] if pages.empty?
          
          rows = []
          page_numbers = pages.dup
          
          page_numbers.each do |page_number|
            page = read_page(page_number)
            
            # Scan records on the page
            offset = PageHeader::SIZE
            
            while offset < page.header.data_end
              # Read record header
              record_header = page.read(offset, 16)
              break if record_header.nil? || record_header.bytesize < 16
              
              record_id, record_size, flags, col_count = record_header.unpack("Q>L>S>S")
              offset += 16
              
              # Read record data
              record_data = page.read(offset, record_size)
              offset += record_size
              
              # Deserialize row
              row = Deserializer.deserialize_row(record_data, columns)
              row[:_row_id] = record_id
              
              # Check visibility
              transaction_id = conditions[:transaction_id] || 0
              if conditions[:visibility_check] != false
                unless @visibility_map.is_visible?(record_id, transaction_id)
                  next
                end
              end
              
              # Apply conditions
              if matches_conditions?(row, conditions)
                rows << row
              end
            end
          end
          
          # Apply limit and offset
          if conditions[:limit]
            offset_val = conditions[:offset] || 0
            rows = rows[offset_val, conditions[:limit]]
          end
          
          rows
        end
      end

      def select_row(table_name, row_id, columns)
        @lock.synchronize do
          # Check cache first
          cache_key = "#{table_name}:#{row_id}"
          if @row_cache.key?(cache_key)
            cached_row, cached_time = @row_cache[cache_key]
            if Time.now - cached_time < @cache_ttl
              @stats[:cache_hits] += 1
              return cached_row
            end
          end
          @stats[:cache_misses] += 1
          
          rows = select_rows(table_name, columns, { row_id: row_id, limit: 1 })
          row = rows.first
          
          # Cache the result
          if row
            @row_cache[cache_key] = [row, Time.now]
            cleanup_cache if @row_cache.size > @cache_size
          end
          
          row
        end
      end

      def update_row(table_name, row_id, values, conditions = {})
        @lock.synchronize do
          @stats[:row_updates] += 1
          
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          
          transaction_id = conditions[:transaction_id] || 0
          
          # Find the row
          updated = false
          pages = @table_pages[table_name] || []
          
          pages.each do |page_number|
            page = read_page(page_number)
            offset = PageHeader::SIZE
            
            while offset < page.header.data_end
              record_header = page.read(offset, 16)
              break if record_header.nil? || record_header.bytesize < 16
              
              record_id, record_size, flags, col_count = record_header.unpack("Q>L>S>S")
              
              if record_id == row_id
                # Check visibility
                if conditions[:visibility_check] != false
                  unless @visibility_map.is_visible?(row_id, transaction_id)
                    break
                  end
                end
                
                # Read current row data
                record_data = page.read(offset + 16, record_size)
                columns = metadata[:columns]
                current_row = Deserializer.deserialize_row(record_data, columns)
                
                # Update values
                values.each do |key, value|
                  current_row[key] = value
                end
                
                # Create updated row
                row = Row.new(row_id, columns, current_row)
                new_row_data = Serializer.serialize_row(row, columns)
                
                # Check if we have enough space for the updated row
                new_size = new_row_data.bytesize
                old_size = record_size
                
                if new_size != old_size
                  # Need to rewrite the row
                  # Mark the old row as deleted/hidden
                  flags |= 0x01  # Deleted flag
                  
                  # Write updated header with new size
                  page.write(offset, [record_id, new_size, flags, col_count].pack("Q>L>S>S"))
                  
                  # Write new data (may overlap with old data)
                  if new_size <= old_size
                    # Can write in place
                    page.write(offset + 16, new_row_data)
                  else
                    # Need to move to end of page
                    new_offset = page.header.data_end
                    page.write(new_offset, [record_id, new_size, flags, col_count].pack("Q>L>S>S"))
                    page.write(new_offset + 16, new_row_data)
                    page.header.data_end = new_offset + 16 + new_size
                  end
                else
                  # Same size - update in place
                  page.write(offset + 16, new_row_data)
                end
                
                # Mark old version as hidden
                @visibility_map.mark_hidden(row_id, transaction_id)
                
                # Mark new version as visible
                @visibility_map.mark_visible(row_id, transaction_id)
                
                page.write_header
                write_page(page)
                updated = true
                break
              end
              
              offset += 16 + record_size
            end
            
            break if updated
          end
          
          if updated
            # Invalidate cache
            invalidate_cache(table_name, row_id)
            
            # Update metadata
            metadata[:updated_at] = Time.now
            save_table_metadata
          end
          
          updated
        end
      end

      def delete_row(table_name, row_id, conditions = {})
        @lock.synchronize do
          @stats[:row_deletes] += 1
          
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          
          transaction_id = conditions[:transaction_id] || 0
          
          # Find and delete the row
          deleted = false
          pages = @table_pages[table_name] || []
          
          pages.each do |page_number|
            page = read_page(page_number)
            offset = PageHeader::SIZE
            
            while offset < page.header.data_end
              record_header = page.read(offset, 16)
              break if record_header.nil? || record_header.bytesize < 16
              
              record_id, record_size, flags, col_count = record_header.unpack("Q>L>S>S")
              
              if record_id == row_id
                # Check visibility
                if conditions[:visibility_check] != false
                  unless @visibility_map.is_visible?(row_id, transaction_id)
                    break
                  end
                end
                
                # Mark as deleted in visibility map
                @visibility_map.mark_deleted(row_id, transaction_id)
                
                # Mark record as deleted on page
                flags |= 0x01  # Deleted flag
                page.write(offset, [record_id, record_size, flags, col_count].pack("Q>L>S>S"))
                page.write_header
                write_page(page)
                
                deleted = true
                break
              end
              
              offset += 16 + record_size
            end
            
            break if deleted
          end
          
          if deleted
            # Invalidate cache
            invalidate_cache(table_name, row_id)
            
            # Update metadata
            metadata[:updated_at] = Time.now
            save_table_metadata
          end
          
          deleted
        end
      end

      # Transaction support
      def begin_transaction(isolation_level = :read_committed)
        @lock.synchronize do
          @stats[:transaction_begin] += 1
          
          transaction_id = next_transaction_id
          @transaction_manager = {
            id: transaction_id,
            started_at: Time.now,
            isolation_level: isolation_level,
            active: true,
            changes: {}
          }
          
          # Register transaction with visibility map
          @visibility_map.register_transaction(transaction_id)
          
          # Create snapshot if needed
          if isolation_level == :repeatable_read || isolation_level == :serializable
            @visibility_map.create_snapshot(transaction_id)
          end
          
          transaction_id
        end
      end

      def current_transaction
        @transaction_manager
      end

      def commit_transaction(transaction = nil)
        @lock.synchronize do
          @stats[:transaction_commit] += 1
          
          tx = transaction || @transaction_manager
          return false unless tx && tx[:active]
          
          # Commit transaction in visibility map
          @visibility_map.commit_transaction(tx[:id])
          
          # Flush all changes
          flush
          
          tx[:active] = false
          tx[:committed_at] = Time.now
          
          true
        end
      end

      def rollback_transaction(transaction = nil)
        @lock.synchronize do
          @stats[:transaction_rollback] += 1
          
          tx = transaction || @transaction_manager
          return false unless tx && tx[:active]
          
          # Rollback transaction in visibility map
          @visibility_map.abort_transaction(tx[:id])
          
          # Rollback changes
          if tx[:changes]
            tx[:changes].each do |table_name, rows|
              rows.each do |row_id, change|
                if change[:type] == :insert
                  # Remove inserted row
                  # This is simplified - in production we'd need to remove from storage
                elsif change[:type] == :update
                  # Restore old values
                  # This is simplified
                elsif change[:type] == :delete
                  # Restore deleted row
                  # This is simplified
                end
              end
            end
          end
          
          tx[:active] = false
          tx[:aborted_at] = Time.now
          
          true
        end
      end

      def in_transaction?
        @transaction_manager && @transaction_manager[:active]
      end

      # Cache operations
      def invalidate_cache(table_name, row_id = nil)
        if row_id
          @row_cache.delete("#{table_name}:#{row_id}")
        else
          # Invalidate all rows for table
          @row_cache.delete_if { |key, _| key.start_with?("#{table_name}:") }
        end
      end

      def clear_cache
        @row_cache.clear
        @stats[:cache_hits] = 0
        @stats[:cache_misses] = 0
      end

      # Utility operations
      def flush
        @storage_manager.flush
        @visibility_map.flush
        save_table_metadata
      end

      def close
        return unless @is_open
        
        flush
        @storage_manager.close
        @is_open = false
        true
      end

      def stats
        @lock.synchronize do
          {
            table_count: @table_metadata.size,
            row_count: @table_metadata.values.sum { |m| m[:row_count] || 0 },
            page_count: @page_manager.total_pages,
            free_pages: @page_manager.free_pages,
            used_pages: @page_manager.used_pages,
            buffer_size: @buffer_pool.size,
            cache_size: @row_cache.size,
            cache_hits: @stats[:cache_hits],
            cache_misses: @stats[:cache_misses],
            cache_hit_rate: cache_hit_rate,
            table_creates: @stats[:table_creates],
            row_inserts: @stats[:row_inserts],
            row_selects: @stats[:row_selects],
            row_updates: @stats[:row_updates],
            row_deletes: @stats[:row_deletes],
            transaction_begin: @stats[:transaction_begin],
            transaction_commit: @stats[:transaction_commit],
            transaction_rollback: @stats[:transaction_rollback],
            is_open: @is_open,
            visibility_rows: @visibility_map.visibility_info.size,
            active_transactions: @visibility_map.active_transaction_count
          }
        end
      end

      def open?
        @is_open
      end

      def vacuum
        @visibility_map.vacuum
        save_table_metadata
      end

      def compact_table(table_name)
        @lock.synchronize do
          metadata = @table_metadata[table_name]
          return false unless metadata
          
          pages = @table_pages[table_name] || []
          compacted_count = 0
          
          pages.each do |page_number|
            result = @page_allocator.compact_page(page_number)
            compacted_count += 1 if result[:compacted]
          end
          
          compacted_count > 0
        end
      end

      private

      def get_or_allocate_data_page(table_name)
        metadata = @table_metadata[table_name]
        pages = @table_pages[table_name] || []
        
        if pages.empty?
          # Allocate first page
          page_number = allocate_page(StorageLayout::PAGE_TYPE_TABLE)
          pages << page_number
          @table_pages[table_name] = pages
          metadata[:first_page] = page_number
          metadata[:last_page] = page_number
          return page_number
        end
        
        # Check if last page has space
        last_page = pages.last
        page = read_page(last_page)
        
        if page.free_space < 1000  # Less than 1KB free
          # Allocate new page
          new_page = allocate_page(StorageLayout::PAGE_TYPE_TABLE)
          pages << new_page
          @table_pages[table_name] = pages
          metadata[:last_page] = new_page
          return new_page
        end
        
        last_page
      end

      def matches_conditions?(row, conditions)
        conditions.each do |key, value|
          next if key == :transaction_id || key == :visibility_check || 
                  key == :limit || key == :offset || key == :row_id
          
          if key == :_row_id
            return false unless row[:_row_id] == value
          elsif row[key] != value
            return false
          end
        end
        
        # Check row_id condition
        if conditions[:row_id]
          return false unless row[:_row_id] == conditions[:row_id]
        end
        
        true
      end

      def cache_hit_rate
        total = @stats[:cache_hits] + @stats[:cache_misses]
        return 0.0 if total == 0
        (@stats[:cache_hits].to_f / total * 100).round(2)
      end

      def cleanup_cache
        if @row_cache.size > @cache_size
          # Remove oldest entries
          sorted = @row_cache.sort_by { |_, (_, time)| time }
          remove_count = (@row_cache.size - @cache_size) * 0.2
          sorted.first(remove_count.to_i).each do |key, _|
            @row_cache.delete(key)
          end
        end
      end

      def next_transaction_id
        @next_transaction_id ||= 1
        @next_transaction_id += 1
        @next_transaction_id
      end

      def load_table_metadata
        @lock.synchronize do
          begin
            metadata_path = "#{@path}.metadata"
            if File.exist?(metadata_path)
              data = File.read(metadata_path)
              parsed = JSON.parse(data, symbolize_names: true)
              
              parsed[:tables]&.each do |table_name, table_data|
                @table_metadata[table_name] = {
                  metadata_page: table_data[:metadata_page],
                  data_page: table_data[:data_page],
                  columns: table_data[:columns]&.map { |c| Column.new(c[:name], c[:type]) } || [],
                  column_count: table_data[:column_count] || 0,
                  row_count: table_data[:row_count] || 0,
                  created_at: Time.at(table_data[:created_at]),
                  updated_at: Time.at(table_data[:updated_at])
                }
                @table_pages[table_name] = table_data[:pages] || []
              end
            end
          rescue => e
            # If loading fails, start fresh
            @table_metadata.clear
            @table_pages.clear
          end
        end
      end

      def save_table_metadata
        @lock.synchronize do
          begin
            data = {
              tables: {}
            }
            
            @table_metadata.each do |table_name, metadata|
              data[:tables][table_name] = {
                metadata_page: metadata[:metadata_page],
                data_page: metadata[:data_page],
                columns: metadata[:columns].map { |c| { name: c.name, type: c.type_class } },
                column_count: metadata[:column_count],
                row_count: metadata[:row_count],
                created_at: metadata[:created_at].to_i,
                updated_at: metadata[:updated_at].to_i,
                pages: @table_pages[table_name] || []
              }
            end
            
            metadata_path = "#{@path}.metadata"
            temp_path = "#{metadata_path}.tmp"
            File.write(temp_path, JSON.generate(data))
            File.rename(temp_path, metadata_path)
          rescue => e
            # Log error but continue
          end
        end
      end

      def start_cleanup_thread
        Thread.new do
          loop do
            sleep(3600)  # Run every hour
            begin
              # Clean up old cache entries
              cleanup_cache
              
              # Run vacuum
              vacuum
              
              # Save metadata
              save_table_metadata
            rescue => e
              # Log error but continue
            end
          end
        end
      end
    end
  end
end