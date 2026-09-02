# frozen_string_literal: true


# Standard library
require "json"
require "set"
require "securerandom"
require "fileutils"
require "monitor"

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
require_relative "../mvcc/version_store"
require_relative "storage_layout"
require_relative "../indexes/index"
require_relative "../indexes/btree"
require_relative "../indexes/btree_node"
require_relative "../indexes/btree_cursor"
require_relative "../indexes/hash_index"
require_relative "../indexes/index_manager"

# Catalog components
require_relative "../catalog/catalog"
require_relative "../catalog/table"
require_relative "../catalog/column"

# WAL and Recovery
require_relative "../wal/wal"
require_relative "../recovery/crash_recovery"

# Types
require_relative "../types/type"
require_relative "../constraints/constraint"
require_relative "../constraints/check"

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
      NULL_BITMAP_FLAG = 0x02
      VARIABLE_LENGTH_PREFIXES_FLAG = 0x04

      attr_reader :storage_manager, :buffer_pool, :page_manager, :catalog, :path
      attr_reader :table_metadata, :transaction_manager, :wal, :crash_recovery, :version_store, :index_manager

      def initialize(path, config = {})
        @path = path
        @config = config
        @catalog = config[:catalog] || Catalog::Catalog.new
        @storage_manager = StorageManager.new(path, config)
        @storage_manager.open

        @buffer_pool = @storage_manager.buffer_pool
        @page_manager = @storage_manager.page_manager
        @page_allocator = @storage_manager.page_allocator
        visibility_path = config[:visibility_path] || "#{path}.visibility"
        visibility_config = config.merge(visibility_path: visibility_path)
        @visibility_map = VisibilityMap.new(@page_manager, visibility_config)
        @version_store = MVCC::VersionStore.new(persistence_path: config[:mvcc_path] || "#{path}.mvcc")
        @transaction_versions = Hash.new { |hash, key| hash[key] = [] }
        @transaction_snapshots = {}
        @transaction_reads = Hash.new { |hash, key| hash[key] = Set.new }
        @transaction_writes = Hash.new { |hash, key| hash[key] = Set.new }
        @transaction_predicates = Hash.new { |hash, key| hash[key] = Set.new }
        @table_metadata = {}
        @table_pages = {}
        @row_cache = {}
        @cache_size = config[:cache_size] || 1000
        @cache_ttl = config[:cache_ttl] || 300  # 5 minutes
        @is_open = true
        @transaction_manager = nil
        @current_transaction_id = 0
        @recovery_in_progress = false
        @stats = {
          table_creates: 0,
          row_inserts: 0,
          row_selects: 0,
          row_updates: 0,
          row_deletes: 0,
          index_scans: 0,
          cache_hits: 0,
          cache_misses: 0,
          transaction_begin: 0,
          transaction_commit: 0,
          transaction_rollback: 0,
          wal_writes: 0,
          crash_recoveries: 0
        }
        @lock = Monitor.new
        
        # Initialize WAL
        wal_dir = config[:wal_dir] || "#{path}.wal"
        @wal = WAL::WAL.new(wal_dir, recovery: false)  # Defer recovery until after metadata load
        @wal.attach_engine(self)
        
        # Initialize crash recovery
        @crash_recovery = Recovery::CrashRecovery.new(self, @wal, config)
        
        # Load table metadata from disk
        load_table_metadata

        # Recovery needs table metadata before replaying WAL records.
        run_crash_recovery

        # Build/load indexes only after metadata and crash recovery are ready.
        @index_manager = Indexes::IndexManager.new(self)
        
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
      def create_table(table_name, columns = nil, options = {}, &block)
        if columns.is_a?(Hash) && options.empty?
          options = columns
          columns = nil
        end
        columns ||= []
        if block
          builder = Object.new
          builder.define_singleton_method(:column) do |name, type, **column_options|
            columns << Catalog::Column.new(name, type, **column_options)
          end
          block.call(builder)
        end

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
            constraints: serialize_constraint_definitions(options[:constraints] || []),
            created_at: Time.now,
            updated_at: Time.now
          }
          
          @table_pages[table_name] = [data_page]
          
          # Add to catalog
          @catalog.create_table(table_name) do |t|
            columns.each do |col|
              t.column(col.name, col.type_class, **col.options)
            end
          end if @catalog && @catalog.current_database
          
          # Save metadata to disk
          save_table_metadata
          
          true
        end
      end

      def drop_table(table_name, options = {})
        table_name = resolve_table_name(table_name)
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

      def add_column(table_name, column_name, type, options = {})
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          table_key = @table_metadata.key?(table_name) ? table_name : table_name.to_sym
          metadata = @table_metadata[table_key]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          raise DatabaseError, "Column '#{column_name}' already exists" if metadata[:columns].any? { |column| column.name.to_s == column_name.to_s }

          column = Catalog::Column.new(column_name, type, **options)
          rows = select_rows(table_key, metadata[:columns])
          if !column.nullable? && !column.has_default? && !rows.empty?
            raise DatabaseError, "Column '#{column_name}' requires a default for existing rows"
          end
          metadata[:columns] << column
          metadata[:column_count] = metadata[:columns].size
          metadata[:updated_at] = Time.now
          rewrite_table_metadata_page(table_key, metadata)
          @catalog.find_table(table_key)&.add_column(column) if @catalog&.current_database
          save_table_metadata
          true
        end
      end

      def drop_column(table_name, column_name)
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          table_key = @table_metadata.key?(table_name) ? table_name : table_name.to_sym
          metadata = @table_metadata[table_key]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          column = metadata[:columns].find { |candidate| candidate.name.to_s == column_name.to_s }
          raise DatabaseError, "Column '#{column_name}' does not exist" unless column
          raise DatabaseError, "Cannot drop the only column" if metadata[:columns].size == 1

          metadata[:columns].delete(column)
          metadata[:column_count] = metadata[:columns].size
          metadata[:updated_at] = Time.now
          rewrite_table_metadata_page(table_key, metadata)
          @catalog.find_table(table_key)&.drop_column(column_name) if @catalog&.current_database
          save_table_metadata
          true
        end
      end

      def add_constraint(table_name, constraint)
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          table_key = @table_metadata.key?(table_name) ? table_name : table_name.to_sym
          metadata = @table_metadata[table_key]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata

          definition = constraint_definition(constraint)
          name = definition[:name].to_s
          raise DatabaseError, "Constraint name cannot be empty" if name.empty?
          if (metadata[:constraints] || []).any? { |existing| existing[:name].to_s == name }
            raise DatabaseError, "Constraint '#{name}' already exists"
          end

          columns = definition[:columns].to_a.map(&:to_sym)
          known_columns = metadata[:columns].map { |column| column.name.to_sym }
          unknown = columns - known_columns
          raise DatabaseError, "Column '#{unknown.first}' does not exist" unless unknown.empty?
          if definition[:type].to_s.casecmp("foreign_key").zero? && !@table_metadata.key?(definition[:reference_table]) && !@table_metadata.key?(definition[:reference_table].to_sym)
            raise DatabaseError, "Referenced table '#{definition[:reference_table]}' does not exist"
          end

          rows = select_rows(table_key, metadata[:columns], visibility_check: false)
          if definition[:type].to_s.casecmp("unique").zero?
            seen = {}
            rows.each do |row|
              key = columns.map { |column| row[column] || row[column.to_s] }
              next if key.all?(&:nil?)
              raise DatabaseError, "Duplicate value for #{columns.join(', ')} on '#{table_name}'" if seen[key]
              seen[key] = true
            end
          end

          metadata[:constraints] ||= []
          metadata[:constraints] << definition
          metadata[:updated_at] = Time.now
          save_table_metadata
          true
        end
      end

      def drop_constraint(table_name, constraint_name)
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          table_key = @table_metadata.key?(table_name) ? table_name : table_name.to_sym
          metadata = @table_metadata[table_key]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          constraints = metadata[:constraints] || []
          index = constraints.index { |constraint| constraint[:name].to_s == constraint_name.to_s }
          raise DatabaseError, "Constraint '#{constraint_name}' does not exist" unless index
          constraints.delete_at(index)
          metadata[:updated_at] = Time.now
          save_table_metadata
          true
        end
      end

      def table_exists?(table_name)
        @table_metadata.key?(resolve_table_name(table_name))
      end

      def list_tables
        @table_metadata.keys
      end

      # Return a replayable SQL description of the persisted catalog. Backup
      # providers use this as the human-readable schema component alongside
      # the physical data files.
      def schema_dump
        list_tables.map do |table_name|
          columns = table_columns(table_name)
          definitions = columns.map do |column|
            definition = [quote_identifier(column.name), sql_type_name(column.type)]
            definition << "PRIMARY KEY" if column.primary_key?
            definition << "UNIQUE" if column.unique? && !column.primary_key?
            definition << "NOT NULL" unless column.nullable?
            definition << "DEFAULT #{sql_literal(column.default)}" if column.has_default?
            definition.join(" ")
          end
          "CREATE TABLE #{quote_identifier(table_name)} (#{definitions.join(', ')});"
        end.join("\n") + (list_tables.empty? ? "" : "\n")
      end

      def current_database_name
        @catalog.current_database_name || @config[:database] || File.basename(@path, File.extname(@path))
      end

      def quote_identifier(identifier)
        "\"#{identifier.to_s.gsub('"', '""')}\""
      end

      def sql_type_name(type)
        if type.is_a?(Hash)
          type[:type] || type["type"] || type.to_s
        else
          type.to_s
        end.to_s.upcase
      end

      def sql_literal(value)
        case value
        when nil then "NULL"
        when Numeric then value.to_s
        when TrueClass then "TRUE"
        when FalseClass then "FALSE"
        else "'#{value.to_s.gsub("'", "''")}'"
        end
      end

      # Apply a logical replication envelope. Only explicit row mutations are
      # accepted; unknown envelopes fail closed instead of being ignored.
      def apply_transaction(transaction_data)
        data = transaction_data.transform_keys { |key| key.to_sym rescue key }
        operation = (data[:operation] || data[:type]).to_s.downcase
        table = data[:table_name] || data[:table]
        table = table.to_sym if table && !@table_metadata.key?(table) && @table_metadata.key?(table.to_sym)

        case operation
        when "insert"
          columns = table_columns(table)
          values = data[:values] || data[:row]
          insert_row(table, columns, values)
        when "update"
          update_row(table, data[:row_id], data[:values] || data[:row], data[:conditions] || {})
        when "delete"
          delete_row(table, data[:row_id], data[:conditions] || {})
        else
          raise ReplicationError, "Unsupported logical replication operation: #{operation}"
        end
      end

      # Files belonging to this database, including persisted metadata used by
      # MVCC and catalog reconstruction. Backup providers use these explicit
      # paths instead of guessing from the primary data file.
      def data_files
        [@path, "#{@path}.metadata", "#{@path}.visibility", "#{@path}.mvcc"].select { |file| File.file?(file) }
      end

      # Export the logical database state used by physical branch checkout.
      # The export is detached from live metadata and contains no internal
      # page identifiers, so it can be safely persisted in a branch catalog.
      def export_state
        list_tables.each_with_object({}) do |table_name, state|
          columns = table_columns(table_name)
          state[table_name] = {
            columns: columns.map(&:serialize),
            rows: select_rows(table_name, columns, visibility_check: false).map do |row|
              row.reject { |key, _| key.to_sym == :_row_id }
            end
          }
        end
      end

      # Replace the logical database state with a branch base snapshot and
      # replay its committed logical changes. Unknown change operations fail
      # before mutating the database.
      def apply_branch_state(state)
        state = state.transform_keys(&:to_sym) if state.respond_to?(:transform_keys)
        base = state[:base]
        changes = Array(state[:changes])
        raise DatabaseError, "Branch has no persisted base snapshot" unless base.is_a?(Hash)

        unsupported = changes.reject do |change|
          operation = (change[:operation] || change["operation"] || change[:type] || change["type"]).to_s
          %w[insert update delete].include?(operation.downcase)
        end
        raise DatabaseError, "Unsupported branch change operation" unless unsupported.empty?

        restore_exported_state(base)
        changes.each { |change| apply_branch_change(change) }
        true
      end

      private

      # Metadata loaded from JSON may contain symbol keys while callers use
      # strings (or vice versa). Keep the original key for catalog/index
      # compatibility, but accept either public representation.
      def resolve_table_name(table_name)
        return table_name if @table_metadata.key?(table_name)

        alternate = table_name.is_a?(Symbol) ? table_name.to_s : table_name.to_s.to_sym
        @table_metadata.key?(alternate) ? alternate : table_name
      end

      def restore_exported_state(state)
        current_tables = list_tables.dup
        current_tables.each { |table| drop_table(table) }
        state.each do |table_name, table_state|
          data = table_state.transform_keys(&:to_sym)
          columns = Array(data[:columns]).map do |column|
            Catalog::Column.deserialize(column.transform_keys(&:to_sym))
          end
          create_table(table_name.to_s, columns)
          Array(data[:rows]).each do |row|
            values = row.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
            insert_row(table_name.to_s, columns, values)
          end
        end
      end

      def apply_branch_change(change)
        data = change.transform_keys(&:to_sym)
        table = data[:table_name] || data[:table]
        case (data[:operation] || data[:type]).to_s.downcase
        when "insert"
          values = data[:values] || data[:row] || {}
          columns = table_columns(table)
          normalized = columns.to_h { |column| [column.name, values[column.name] || values[column.name.to_sym]] }
          insert_row(table, columns, normalized)
        when "update"
          update_row(table, data[:row_id], (data[:values] || {}).transform_keys(&:to_sym), visibility_check: false)
        when "delete"
          delete_row(table, data[:row_id], visibility_check: false)
        end
      end

      public

      def wal_dir
        @config[:wal_dir] || "#{@path}.wal"
      end

      def wal_files
        Dir.glob(File.join(wal_dir, "wal_*.log"))
      end

      def data_dir
        File.dirname(@path)
      end

      def table_columns(table_name)
        metadata = @table_metadata[resolve_table_name(table_name)]
        return [] unless metadata
        metadata[:columns]
      end

      def table_row_count(table_name)
        metadata = @table_metadata[resolve_table_name(table_name)]
        return 0 unless metadata
        metadata[:row_count] || 0
      end

      # Row operations
      def insert_row(table_name, columns, values)
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          @stats[:row_inserts] += 1
          
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata

          validate_constraints!(table_name, metadata, columns, values)
          validate_relational_constraints!(table_name, metadata, columns, values)
          row_for_index = if values.is_a?(Hash)
                            values.merge(_row_id: metadata[:row_count] + 1)
                          else
                            columns.each_with_index.to_h { |column, index| [column.name, values[index]] }.merge(_row_id: metadata[:row_count] + 1)
                          end
          @index_manager&.validate_insert!(table_name, row_for_index)
          
          # Get the last data page or allocate new one
          data_page = get_or_allocate_data_page(table_name)
          page = read_page(data_page)
          
          # Create row
          row_id = metadata[:row_count] + 1
          row = Row.new(row_id, columns, values)
          
          # Serialize row data
          row_data = Serializer.serialize_row(row, columns, null_bitmap: true)
          
          # Log to WAL before writing to page
          log_to_wal(WAL::Record::TYPE_INSERT, {
            table_name: table_name,
            row_id: row_id,
            page: data_page,
            values: values
          }, @current_transaction_id)
          
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
          flags = NULL_BITMAP_FLAG | VARIABLE_LENGTH_PREFIXES_FLAG
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
          record_transaction_change(:insert, table_name, row_id, values: values, columns: columns)
          record_mvcc_version(table_name, row_id, values, @current_transaction_id)

          @index_manager&.insert_row(table_name, values.merge(_row_id: row_id)) if values.is_a?(Hash)
          if values.is_a?(Array)
            @index_manager&.insert_row(table_name, columns.each_with_index.to_h { |column, index| [column.name, values[index]] }.merge(_row_id: row_id))
          end
          
          # Update catalog
          if @catalog && @catalog.current_database
            table = @catalog.find_table(table_name)
            table.row_count = metadata[:row_count] if table
          end
          
          # Save metadata
          save_table_metadata
          
          # Invalidate cache
          invalidate_cache(table_name, row_id)
          fire_triggers(:insert, table_name, values, row_id)
          
          row_id
        end
      end

      def select_rows(table_name, columns, conditions = {})
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          @stats[:row_selects] += 1
          
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          
          # Get all data pages for the table
          pages = @table_pages[table_name] || []
          return [] if pages.empty?
          
          rows = []
          seen_row_ids = {}
          indexed_row_ids = indexed_row_ids_for(table_name, conditions)
          @stats[:index_scans] = (@stats[:index_scans] || 0) + 1 if indexed_row_ids
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

              # Deleted row versions remain on the page until vacuum/compact;
              # they must not be visible to ordinary scans.
              if (flags & 0x01) != 0
                offset += record_size
                next
              end
              if indexed_row_ids && !indexed_row_ids.include?(record_id)
                offset += record_size
                next
              end
              
              # Read record data
              record_data = page.read(offset, record_size)
              offset += record_size
              
              # Deserialize the physical row, then select the historical
              # version for REPEATABLE READ transactions when available.
              row = Deserializer.deserialize_row(
                record_data,
                columns,
                null_bitmap: (flags & NULL_BITMAP_FLAG) != 0,
                variable_length_prefixes: (flags & VARIABLE_LENGTH_PREFIXES_FLAG) != 0
              )
              # Older physical records may have fewer fields after an ADD
              # COLUMN. Materialize the declared column default at read time
              # without rewriting the original row or changing its identity.
              if col_count < columns.size
                columns.each_with_index do |column, index|
                  row[column.name] = column.default if index >= col_count && column.has_default?
                end
              end
              snapshot = @transaction_snapshots[@current_transaction_id]
              if snapshot
                @transaction_reads[@current_transaction_id].add(version_key(table_name, record_id))
                version = @version_store.get_latest_version(
                  record_id, @current_transaction_id, snapshot,
                  key: version_key(table_name, record_id)
                )
                next if version.nil? && @version_store.keys(version_key(table_name, record_id)).any?
                if version
                  row = version.data.is_a?(Array) ?
                    columns.each_with_index.to_h { |column, index| [column.name, version.data[index]] } : version.data.dup
                end
              end
              row[:_row_id] = record_id
              seen_row_ids[record_id] = true
              
              # Active transactions must not read uncommitted or deleted
              # versions. Callers can explicitly disable this only for
              # internal recovery/maintenance operations.
              transaction_id = conditions[:transaction_id] || @current_transaction_id
              visibility_check = conditions.key?(:visibility_check) ? conditions[:visibility_check] : in_transaction?
              if visibility_check
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

          # A physical DELETE removes the row from the normal scan, but an
          # older snapshot may still need the last committed version. Walk the
          # table's version keys to restore those historical rows.
          snapshot = @transaction_snapshots[@current_transaction_id]
          if snapshot
            prefix = "#{table_name}\0"
            @version_store.keys(prefix).each do |key|
              row_id = key.to_s.split("\0", 2).last.to_i
              next if seen_row_ids[row_id]

              version = @version_store.get_latest_version(
                row_id, @current_transaction_id, snapshot, key: key
              )
              next unless version

              row = version.data.is_a?(Array) ?
                columns.each_with_index.to_h { |column, index| [column.name, version.data[index]] } : version.data.dup
              row[:_row_id] = row_id
              rows << row if matches_conditions?(row, conditions)
            end
          end

          if @transaction_manager && @transaction_manager[:isolation_level].to_sym == :serializable
            @transaction_predicates[@current_transaction_id].add("#{table_name}\0")
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
        table_name = resolve_table_name(table_name)
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
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          @stats[:row_updates] += 1
          
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          
          transaction_id = conditions[:transaction_id] || @current_transaction_id
          
          updated = false
          old_values = nil
          updated_values = nil
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
                columns = metadata[:columns]
                current_row = Deserializer.deserialize_row(
                  page.read(offset + 16, record_size),
                  columns,
                  null_bitmap: (flags & NULL_BITMAP_FLAG) != 0,
                  variable_length_prefixes: (flags & VARIABLE_LENGTH_PREFIXES_FLAG) != 0
                )
                old_values = current_row.reject { |key, _| key == :_row_id }
                
                # Update values
                values.each do |key, value|
                  current_row[key] = value
                end
                updated_values = current_row.reject { |key, _| key == :_row_id }

                validate_constraints!(table_name, metadata, columns, updated_values, exclude_row_id: row_id)
                validate_relational_constraints!(table_name, metadata, columns, updated_values)
                validate_referential_update!(table_name, old_values, updated_values)
                @index_manager&.validate_update!(table_name, old_values.merge(_row_id: row_id), updated_values.merge(_row_id: row_id))
                
                # Create updated row
                row = Row.new(row_id, columns, current_row)
                new_row_data = Serializer.serialize_row(row, columns, null_bitmap: true)

                # The before-image is captured before the page write, so an
                # interrupted transaction can be undone safely.
                log_to_wal(WAL::Record::TYPE_UPDATE, {
                  table_name: table_name,
                  row_id: row_id,
                  values: values,
                  old_values: old_values
                }, transaction_id)
                
                # Check if we have enough space for the updated row
                new_size = new_row_data.bytesize
                old_size = record_size
                
                if new_size != old_size
                  # Need to rewrite the row
                  # Mark the old row as deleted/hidden
                  flags |= 0x01  # Deleted flag
                  
                  # Write updated header with new size
                  # The old slot remains part of the page layout. Its
                  # physical size must stay unchanged so subsequent records
                  # remain aligned when the replacement is appended.
                  page.write(offset, [record_id, old_size, flags, col_count].pack("Q>L>S>S"))
                  
                  # Write new data (may overlap with old data)
                  if new_size <= old_size
                    # Keep the original physical allocation and mark this
                    # record visible again. Length-prefixed fields allow the
                    # reader to ignore any unused trailing bytes.
                    page.write(offset + 16, new_row_data)
                    page.write(offset, [record_id, old_size, (flags & ~0x01) | NULL_BITMAP_FLAG | VARIABLE_LENGTH_PREFIXES_FLAG, col_count].pack("Q>L>S>S"))
                  else
                    # Need to move to end of page
                    new_offset = page.header.data_end
                    page.write(new_offset, [record_id, new_size, (flags & ~0x01) | NULL_BITMAP_FLAG | VARIABLE_LENGTH_PREFIXES_FLAG, col_count].pack("Q>L>S>S"))
                    page.write(new_offset + 16, new_row_data)
                    page.header.data_end = new_offset + 16 + new_size
                  end
                else
                  # Same size - update in place
                  page.write(offset + 16, new_row_data)
                  page.write(offset, [record_id, record_size, flags | VARIABLE_LENGTH_PREFIXES_FLAG, col_count].pack("Q>L>S>S"))
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
            record_transaction_change(:update, table_name, row_id, old_values: old_values, values: values)
            record_mvcc_version(table_name, row_id, updated_values, transaction_id)
            @index_manager&.update_row(table_name, old_values.merge(_row_id: row_id), updated_values.merge(_row_id: row_id))
            apply_referential_update!(table_name, old_values, updated_values)
            fire_triggers(:update, table_name, updated_values, row_id, old_row: old_values)
          end
          
          updated
        end
      end

      def delete_row(table_name, row_id, conditions = {})
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          @stats[:row_deletes] += 1
          
          metadata = @table_metadata[table_name]
          raise DatabaseError, "Table '#{table_name}' does not exist" unless metadata
          
          transaction_id = conditions[:transaction_id] || @current_transaction_id
          
          deleted = false
          old_values = nil
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

                record_data = page.read(offset + 16, record_size)
                columns = metadata[:columns]
                current_row = Deserializer.deserialize_row(
                  record_data,
                  columns,
                  null_bitmap: (flags & NULL_BITMAP_FLAG) != 0,
                  variable_length_prefixes: (flags & VARIABLE_LENGTH_PREFIXES_FLAG) != 0
                )
                old_values = current_row.reject { |key, _| key == :_row_id }
                old_values_array = columns.map { |column| old_values[column.name] }

                validate_referential_delete!(table_name, metadata, old_values)

                log_to_wal(WAL::Record::TYPE_DELETE, {
                  table_name: table_name,
                  row_id: row_id,
                  columns: columns,
                  row_data: old_values_array,
                  old_values: old_values
                }, transaction_id)
                
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
            record_transaction_change(:delete, table_name, row_id, old_values: old_values, columns: metadata[:columns])
            record_mvcc_version(table_name, row_id, old_values.merge(_deleted: true), transaction_id, deleted: true)
            @index_manager&.delete_row(table_name, old_values.merge(_row_id: row_id))
            fire_triggers(:delete, table_name, old_values, row_id)
          end
          
          deleted
        end
      end

      def restore_deleted_row(table_name, row_id)
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          metadata = @table_metadata[table_name]
          return false unless metadata

          (@table_pages[table_name] || []).each do |page_number|
            page = read_page(page_number)
            offset = PageHeader::SIZE
            while offset < page.header.data_end
              header = page.read(offset, 16)
              break if header.nil? || header.bytesize < 16

              record_id, record_size, flags, col_count = header.unpack("Q>L>S>S")
              if record_id == row_id && (flags & 0x01) != 0
                page.write(offset, [record_id, record_size, flags & ~0x01, col_count].pack("Q>L>S>S"))
                page.write_header
                write_page(page)
                @visibility_map.mark_visible(row_id, 0)
                invalidate_cache(table_name, row_id)
                return true
              end
              offset += 16 + record_size
            end
          end
          false
        end
      end

      def restore_row_values(table_name, row_id, values)
        table_name = resolve_table_name(table_name)
        @lock.synchronize do
          metadata = @table_metadata[table_name]
          return false unless metadata
          columns = metadata[:columns]
          replacement = Serializer.serialize_row(Row.new(row_id, columns, values), columns, null_bitmap: true)

          (@table_pages[table_name] || []).each do |page_number|
            page = read_page(page_number)
            offset = PageHeader::SIZE
            while offset < page.header.data_end
              header = page.read(offset, 16)
              break if header.nil? || header.bytesize < 16
              record_id, record_size, flags, col_count = header.unpack("Q>L>S>S")
              if record_id == row_id && (flags & 0x01) == 0
                # Append a fresh physical record. Variable-width values have
                # no per-column length prefix, so shrinking in place would
                # leave stale bytes that become part of the next value.
                page.write(offset, [row_id, record_size, 1, col_count].pack("Q>L>S>S"))
                new_offset = page.header.data_end
                  page.write(new_offset, [row_id, replacement.bytesize, NULL_BITMAP_FLAG | VARIABLE_LENGTH_PREFIXES_FLAG, col_count].pack("Q>L>S>S"))
                page.write(new_offset + 16, replacement)
                page.header.data_end = new_offset + 16 + replacement.bytesize
                page.write_header
                write_page(page)
                invalidate_cache(table_name, row_id)
                return true
              end
              offset += 16 + record_size
            end
          end
          false
        end
      end

      # Transaction support
      def begin_transaction(isolation_level = :read_committed)
        @lock.synchronize do
          unless %i[read_committed repeatable_read serializable].include?(isolation_level.to_sym)
            raise DatabaseError, "Isolation level #{isolation_level} is not supported yet"
          end

          # Sessions have independent in-memory maps. Refresh only at the
          # transaction boundary so a new transaction sees commits made by
          # another session without discarding this session's active state.
          @visibility_map.load_visibility
          @version_store.load
          @stats[:transaction_begin] += 1
          
          transaction_id = next_transaction_id
          @transaction_manager = {
            id: transaction_id,
            started_at: Time.now,
            isolation_level: isolation_level,
            active: true,
            changes: {},
            savepoints: {}
          }
          @current_transaction_id = transaction_id

          log_to_wal(WAL::Record::TYPE_BEGIN, {}, transaction_id)
          
          # Register transaction with visibility map
          @visibility_map.register_transaction(transaction_id)
          if %i[repeatable_read serializable].include?(isolation_level.to_sym)
            @transaction_snapshots[transaction_id] = MVCC::Snapshot.new(
              transaction_id,
              @visibility_map.active_transactions.keys,
              @visibility_map.committed_transactions.to_a
            )
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

          # The commit record is the transaction's durable commit point. It
          # must reach the WAL before the transaction is reported committed.
          if (tx[:isolation_level] || :read_committed).to_sym == :serializable
            @version_store.validate_serializable!(
              @transaction_snapshots.fetch(tx[:id]),
              @transaction_reads[tx[:id]],
              @transaction_writes[tx[:id]],
              read_predicates: @transaction_predicates[tx[:id]]
            )
          end
          log_to_wal(WAL::Record::TYPE_COMMIT, {}, tx[:id])
          @wal&.sync
          
          # Commit transaction in visibility map
          @visibility_map.commit_transaction(tx[:id])
          commit_mvcc_versions(tx[:id])
          @transaction_snapshots.delete(tx[:id])
          @transaction_reads.delete(tx[:id])
              @transaction_writes.delete(tx[:id])
          @transaction_predicates.delete(tx[:id])
          
          # Flush all changes
          flush
          
          tx[:active] = false
          tx[:committed_at] = Time.now
          @current_transaction_id = 0
          
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
          abort_mvcc_versions(tx[:id])
          @transaction_snapshots.delete(tx[:id])
          @transaction_reads.delete(tx[:id])
          @transaction_writes.delete(tx[:id])
          @transaction_predicates.delete(tx[:id])
          if tx[:changes]
            tx[:changes].reverse_each do |table_name, rows|
              rows.to_a.reverse_each do |row_id, change|
                if change[:type] == :insert
                  mark_row_deleted(change[:table_name] || table_name, row_id)
                  if @index_manager
                    indexed_row = if change[:values].is_a?(Hash)
                                    change[:values].merge(_row_id: row_id)
                                  elsif change[:columns].is_a?(Array)
                                    change[:columns].each_with_index.to_h { |column, index| [column.respond_to?(:name) ? column.name : column, change[:values][index]] }.merge(_row_id: row_id)
                                  end
                    @index_manager.delete_row(change[:table_name] || table_name, indexed_row) if indexed_row
                  end
                elsif change[:type] == :update
                  restore_row_values(change[:table_name] || table_name, row_id, change[:old_values] || {})
                elsif change[:type] == :delete
                  table = change[:table_name] || table_name
                  restore_deleted_row(table, row_id)
                  @index_manager&.insert_row(table, change[:old_values].merge(_row_id: row_id)) if change[:old_values].is_a?(Hash)
                end
              end
            end
          end
          
          tx[:active] = false
          tx[:aborted_at] = Time.now

          log_to_wal(WAL::Record::TYPE_ROLLBACK, {}, tx[:id])
          @wal&.sync
          @current_transaction_id = 0
          
          true
        end
      end

      def in_transaction?
        @transaction_manager && @transaction_manager[:active]
      end

      def create_savepoint(name)
        @lock.synchronize do
          tx = @transaction_manager
          raise DatabaseError, "SAVEPOINT requires an active transaction" unless tx && tx[:active]
          name = name.to_s
          tx[:savepoints] ||= {}
          tx[:savepoints][name] = {
            changes: tx[:changes].transform_values { |rows| rows.transform_values(&:dup) },
            version_count: @transaction_versions[tx[:id]].length
          }
          true
        end
      end

      def rollback_to_savepoint(name)
        @lock.synchronize do
          tx = @transaction_manager
          raise DatabaseError, "ROLLBACK TO SAVEPOINT requires an active transaction" unless tx && tx[:active]
          savepoint = tx[:savepoints]&.[](name.to_s)
          raise DatabaseError, "Savepoint '#{name}' does not exist" unless savepoint

          tx[:changes].each do |table_name, rows|
            rows.to_a.reverse_each do |row_id, change|
              next if savepoint[:changes].dig(table_name, row_id)
              case change[:type]
              when :insert
                mark_row_deleted(change[:table_name] || table_name, row_id)
              when :update
                restore_row_values(change[:table_name] || table_name, row_id, change[:old_values] || {})
              when :delete
                table = change[:table_name] || table_name
                restore_deleted_row(table, row_id)
                @index_manager&.insert_row(table, change[:old_values].merge(_row_id: row_id)) if change[:old_values].is_a?(Hash)
              end
            end
          end

          versions = @transaction_versions[tx[:id]]
          versions.slice!(savepoint[:version_count], versions.length) if versions.length > savepoint[:version_count]
          tx[:changes] = savepoint[:changes].transform_values { |rows| rows.transform_values(&:dup) }
          true
        end
      end

      def release_savepoint(name)
        @lock.synchronize do
          tx = @transaction_manager
          raise DatabaseError, "RELEASE SAVEPOINT requires an active transaction" unless tx && tx[:active]
          savepoints = tx[:savepoints] || {}
          raise DatabaseError, "Savepoint '#{name}' does not exist" unless savepoints.delete(name.to_s)
          true
        end
      end

      # Recovery uses the normal storage operations so page/catalog/index
      # maintenance remains centralized, but must not emit new WAL records.
      def with_recovery
        previous = @recovery_in_progress
        @recovery_in_progress = true
        yield
      ensure
        @recovery_in_progress = previous
      end

      def record_transaction_change(type, table_name, row_id, details = {})
        return unless @transaction_manager && @transaction_manager[:active]

        (@transaction_manager[:changes][table_name] ||= {})[row_id] =
          details.merge(type: type, table: table_name, row_id: row_id)
      end

      def record_mvcc_version(table_name, row_id, data, transaction_id, deleted: false)
        return if @recovery_in_progress || !@version_store

        version = @version_store.create_version(row_id, data, transaction_id, key: version_key(table_name, row_id))
              @transaction_writes[transaction_id].add(version_key(table_name, row_id)) if transaction_id.to_i != 0
        version.mark_deleted if deleted
        if transaction_id.to_i == 0
          @version_store.commit_version(version, 0)
        else
          @transaction_versions[transaction_id] << version
        end
      end

      def version_key(table_name, row_id)
        "#{table_name}\0#{row_id}"
      end

      def commit_mvcc_versions(transaction_id)
        @transaction_versions.delete(transaction_id)&.each do |version|
          @version_store.commit_version(version, transaction_id)
        end
        @version_store.persist
      end

      def abort_mvcc_versions(transaction_id)
        @transaction_versions.delete(transaction_id)&.each do |version|
          @version_store.abort_version(version)
        end
        @version_store.persist
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
        
        # Flush WAL first (ensures all mutations are recorded)
        if @wal
          @wal.flush
          @wal.checkpoint.create_checkpoint(@wal.current_lsn)
        end
        
        flush
        @wal&.shutdown
        @version_store&.persist
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
            index_scans: @stats[:index_scans] || 0,
            transaction_begin: @stats[:transaction_begin],
            transaction_commit: @stats[:transaction_commit],
            transaction_rollback: @stats[:transaction_rollback],
            wal_writes: @stats[:wal_writes],
            crash_recoveries: @stats[:crash_recoveries],
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
        result = @visibility_map.vacuum
        save_table_metadata
        result
      end

      def compact_table(table_name)
        table_name = resolve_table_name(table_name)
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

      # Crash recovery
      def run_crash_recovery
        return false unless @wal
        
        # Check if recovery is needed (WAL files exist)
        wal_dir = @config[:wal_dir] || "#{@path}.wal"
        return false unless Dir.exist?(wal_dir) && Dir.glob(File.join(wal_dir, '*.log')).any?
        
        begin
          @stats[:crash_recoveries] += 1
          result = @crash_recovery.recover
          result[:success]
        rescue => e
          warn "Crash recovery failed: #{e.message}"
          false
        end
      end

      # WAL logging helpers
      def log_to_wal(type, data, transaction_id = nil)
        return nil unless @wal && !@recovery_in_progress
        
        transaction_id ||= @current_transaction_id
        record = WAL::Record.new(type, data, transaction_id: transaction_id)
        @stats[:wal_writes] += 1
        
        @wal.write(record)
      end

      private

      def fire_triggers(event, table_name, row, row_id, old_row: nil)
        database = @catalog&.current_database
        return unless database && database.respond_to?(:triggers)

        database.triggers.values.each do |trigger|
          next unless trigger.enabled? && trigger.table_name.to_s == table_name.to_s
          next unless trigger.event_types.map(&:to_sym).include?(event.to_sym)
          next unless trigger.definition.respond_to?(:call)

          trigger.definition.call(
            event: event,
            table_name: table_name,
            row: row,
            old_row: old_row,
            row_id: row_id
          )
        end
      end

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

      def mark_row_deleted(table_name, row_id)
        pages = @table_pages[table_name] || []
        pages.each do |page_number|
          page = read_page(page_number)
          offset = PageHeader::SIZE
          while offset < page.header.data_end
            header = page.read(offset, 16)
            break if header.nil? || header.bytesize < 16
            record_id, record_size, flags, col_count = header.unpack("Q>L>S>S")
            if record_id == row_id && (flags & 0x01).zero?
              page.write(offset, [record_id, record_size, flags | 0x01, col_count].pack("Q>L>S>S"))
              page.write_header
              write_page(page)
              return true
            end
            offset += 16 + record_size
          end
        end
        false
      end

      # Enforce the column-level constraints that are persisted in table
      # metadata before any WAL record or page mutation is produced.
      def validate_constraints!(table_name, metadata, columns, values, exclude_row_id: nil)
        candidate = if values.is_a?(Hash)
                      values.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                    else
                      columns.each_with_index.to_h do |column, index|
                        [column.name.to_sym, values[index]]
                      end
                    end
        schema = metadata[:columns] || columns

        schema.each do |column|
          name = column.name.to_sym
          if (column.primary_key? || !column.nullable?) && candidate[name].nil?
            raise DatabaseError, "Column '#{name}' on '#{table_name}' cannot be NULL"
          end
        end

        constrained_sets = schema.filter_map do |column|
          [column.name.to_sym] if column.primary_key? || column.unique?
        end
        return true if constrained_sets.empty?

        existing_rows = select_rows(table_name, schema, visibility_check: false)
        constrained_sets.each do |column_names|
          key = column_names.map { |name| candidate[name] }
          next if key.all?(&:nil?) && !schema.any? { |column| column.name.to_sym == column_names.first && column.primary_key? }

          duplicate = existing_rows.any? do |existing|
            next false if exclude_row_id && existing[:_row_id] == exclude_row_id
            column_names.all? do |name|
              existing_value = existing.key?(name) ? existing[name] : existing[name.to_s]
              existing_value == candidate[name]
            end
          end
          if duplicate
            raise DatabaseError, "Duplicate value for #{column_names.join(', ')} on '#{table_name}'"
          end
        end
        true
      end

      def validate_relational_constraints!(table_name, metadata, columns, values)
        candidate = if values.is_a?(Hash)
                      values.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                    else
                      columns.each_with_index.to_h { |column, index| [column.name.to_sym, values[index]] }
                    end

        (metadata[:constraints] || []).each do |definition|
          definition = definition.transform_keys(&:to_sym)
          type = definition[:type].to_s.downcase
          case type
          when "unique"
            unique_columns = Array(definition[:columns]).map(&:to_sym)
            next if unique_columns.empty?
            key = unique_columns.map { |column| candidate[column] }
            next if key.all?(&:nil?)
            duplicate = select_rows(table_name, columns, visibility_check: false).any? do |row|
              unique_columns.all? { |column| (row[column] || row[column.to_s]) == candidate[column] }
            end
            raise DatabaseError, "Duplicate value for #{unique_columns.join(', ')} on '#{table_name}'" if duplicate
          when "check"
            expression = definition[:expression]
            constraint = Constraints::CheckConstraint.new(table_name, expression, expression_type: :sql)
            unless constraint.validate(candidate)
              raise DatabaseError, constraint.validation_errors.last
            end
          when "foreign_key", "foreign key"
            foreign_columns = Array(definition[:columns]).map(&:to_sym)
            reference_table = definition[:reference_table]
            reference_columns = Array(definition[:reference_columns] || :id).map(&:to_sym)
            next if foreign_columns.all? { |column| candidate[column].nil? }

            reference_metadata = @table_metadata[reference_table] || @table_metadata[reference_table.to_sym]
            raise DatabaseError, "Referenced table '#{reference_table}' does not exist" unless reference_metadata
            resolved_reference_table = @table_metadata.key?(reference_table) ? reference_table : reference_table.to_sym
            reference_rows = select_rows(resolved_reference_table, reference_metadata[:columns], visibility_check: false)
            found = reference_rows.any? do |reference_row|
              foreign_columns.each_with_index.all? do |column, index|
                reference_value = reference_row[reference_columns[index]] || reference_row[reference_columns[index].to_s]
                reference_value == candidate[column]
              end
            end
            unless found
              raise DatabaseError, "Referenced row does not exist for '#{table_name}'"
            end
          end
        end
        true
      end

      def serialize_constraint_definitions(constraints)
        constraints.map do |constraint|
          definition = if constraint.respond_to?(:to_hash)
                         constraint.to_hash
                       elsif constraint.respond_to?(:columns) || constraint.respond_to?(:condition)
                         constraint_definition(constraint)
                       else
                         constraint
                       end
          definition = definition.transform_keys(&:to_sym)
          {
            type: definition[:type],
            name: definition[:name],
            columns: definition[:columns],
            reference_table: definition[:reference_table],
            reference_columns: definition[:reference_columns],
            on_delete: definition[:on_delete],
            on_update: definition[:on_update],
            expression: definition[:expression]
          }.reject { |_, value| value.nil? }
        end
      end

      def constraint_definition(constraint)
        type = constraint.class.name.split("::").last.sub(/Constraint$/, "").gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase
        definition = { type: type, name: constraint.name }
        definition[:columns] = constraint.columns if constraint.respond_to?(:columns)
        if constraint.respond_to?(:reference_table)
          definition[:reference_table] = constraint.reference_table
          definition[:reference_columns] = constraint.reference_columns
        end
        definition[:on_delete] = constraint.on_delete if constraint.respond_to?(:on_delete)
        definition[:on_update] = constraint.on_update if constraint.respond_to?(:on_update)
        definition[:expression] = constraint.condition.to_sql if constraint.respond_to?(:condition)
        definition
      end

      def matches_conditions?(row, conditions)
        conditions.each do |key, value|
          next if key == :transaction_id || key == :visibility_check || 
                  key == :limit || key == :offset || key == :row_id
          
          if key == :_row_id
            return false unless row[:_row_id] == value
          elsif (row.key?(key) ? row[key] : row[key.to_s]) != value
            if value.is_a?(Hash)
              row_value = row.key?(key) ? row[key] : row[key.to_s]
              return false unless matches_operator?(row_value, value)
            else
              return false
            end
          end
        end
        
        # Check row_id condition
        if conditions[:row_id]
          return false unless row[:_row_id] == conditions[:row_id]
        end
        
        true
      end

      def indexed_row_ids_for(table_name, conditions)
        return nil unless @index_manager
        return nil if conditions.empty?

        index = @index_manager.get_indexes_for_table(table_name).find do |candidate|
          candidate.columns.all? do |column|
            conditions.key?(column) || conditions.key?(column.to_s)
          end
        end
        return nil unless index

        condition = index.columns.map do |column|
          conditions.key?(column) ? conditions[column] : conditions[column.to_s]
        end.first

        if condition.is_a?(Hash)
          operator = (condition[:operator] || condition["operator"]).to_sym
          value = condition[:value] || condition["value"]
          return nil unless %i[between lt lte gt gte].include?(operator)
          if operator == :between
            start_key, end_key = value
          elsif %i[lt lte].include?(operator)
            start_key = range_minimum(value)
            end_key = value
          else
            start_key = value
            end_key = range_maximum(value)
          end
          result = index.range_search(start_key, end_key)
          result = result.map { |entry| entry[:value] || entry[:row_id] }
          result.reject! { |row_id| row_id.nil? }
        else
          key = index.columns.size == 1 ? condition : index.columns.map { |column| conditions[column] }
          result = index.search(key)
        end
        result.is_a?(Array) ? result.to_set : Set.new([result].compact)
      end

      def matches_operator?(row_value, condition)
        operator = (condition[:operator] || condition["operator"]).to_sym
        value = condition[:value] || condition["value"]
        return false if row_value.nil?
        case operator
        when :eq then row_value == value
        when :lt then row_value < value
        when :lte then row_value <= value
        when :gt then row_value > value
        when :gte then row_value >= value
        when :between then row_value >= value[0] && row_value <= value[1]
        else false
        end
      rescue TypeError
        false
      end

      def range_minimum(value)
        value.is_a?(Numeric) ? -Float::INFINITY : ""
      end

      def range_maximum(value)
        value.is_a?(Numeric) ? Float::INFINITY : "\u{10ffff}"
      end

      def validate_referential_delete!(table_name, metadata, deleted_row)
        @table_metadata.each do |child_table, child_metadata|
          (child_metadata[:constraints] || []).each do |definition|
            definition = definition.transform_keys(&:to_sym)
            next unless %w[foreign_key foreign key].include?(definition[:type].to_s.downcase)
            next unless definition[:reference_table].to_s == table_name.to_s

            child_columns = Array(definition[:columns]).map(&:to_sym)
            parent_columns = Array(definition[:reference_columns] || :id).map(&:to_sym)
            child_rows = select_rows(child_table, child_metadata[:columns], visibility_check: false)
            referenced = child_rows.any? do |child_row|
              child_columns.each_with_index.all? do |child_column, index|
                child_value = child_row[child_column] || child_row[child_column.to_s]
                parent_value = deleted_row[parent_columns[index]] || deleted_row[parent_columns[index].to_s]
                !child_value.nil? && child_value == parent_value
              end
            end
            next unless referenced

            action = (definition[:on_delete] || :restrict).to_s.downcase.tr("- ", "__")
            matching_rows = child_rows.select do |child_row|
              child_columns.each_with_index.all? do |child_column, index|
                child_value = child_row[child_column] || child_row[child_column.to_s]
                parent_value = deleted_row[parent_columns[index]] || deleted_row[parent_columns[index].to_s]
                !child_value.nil? && child_value == parent_value
              end
            end

            case action
            when "cascade"
              matching_rows.each do |child_row|
                child_row_id = child_row[:_row_id] || child_row["_row_id"]
                delete_row(child_table, child_row_id, visibility_check: false)
              end
            when "set_null"
              matching_rows.each do |child_row|
                child_row_id = child_row[:_row_id] || child_row["_row_id"]
                updates = child_columns.to_h { |column| [column, nil] }
                update_row(child_table, child_row_id, updates, visibility_check: false)
              end
            when "set_default"
              matching_rows.each do |child_row|
                child_row_id = child_row[:_row_id] || child_row["_row_id"]
                updates = child_columns.each_with_object({}) do |column, result|
                  result[column] = column.default
                end
                update_row(child_table, child_row_id, updates, visibility_check: false)
              end
            when "restrict", "no_action", "noaction"
              raise DatabaseError, "Cannot delete referenced row from '#{table_name}' (ON DELETE #{action.upcase})"
            else
              raise DatabaseError, "Unsupported ON DELETE action: #{action}"
            end
          end
        end
        true
      end

      def validate_referential_update!(table_name, old_row, new_row)
        return true if old_row == new_row

        @table_metadata.each do |child_table, child_metadata|
          (child_metadata[:constraints] || []).each do |raw_definition|
            definition = raw_definition.transform_keys(&:to_sym)
            next unless %w[foreign_key foreign key].include?(definition[:type].to_s.downcase)
            next unless definition[:reference_table].to_s == table_name.to_s

            child_columns = Array(definition[:columns]).map(&:to_sym)
            parent_columns = Array(definition[:reference_columns] || :id).map(&:to_sym)
            next unless parent_columns.any? { |column| old_row[column] != new_row[column] }

            child_rows = select_rows(child_table, child_metadata[:columns], visibility_check: false)
            referenced = child_rows.any? do |child_row|
              child_columns.each_with_index.all? do |child_column, index|
                child_value = child_row[child_column] || child_row[child_column.to_s]
                parent_value = old_row[parent_columns[index]] || old_row[parent_columns[index].to_s]
                !child_value.nil? && child_value == parent_value
              end
            end
            next unless referenced

            action = (definition[:on_update] || :restrict).to_s.downcase.tr("- ", "__")
            case action
            when "cascade", "set_null", "set_default"
              if action == "set_null"
                child_columns.each do |column_name|
                  column = child_metadata[:columns].find { |candidate| candidate.name.to_sym == column_name }
                  raise DatabaseError, "ON UPDATE SET NULL requires nullable column '#{column_name}'" unless column&.nullable?
                end
              end
            when "restrict", "no_action", "noaction"
              raise DatabaseError, "Cannot update referenced row in '#{table_name}' (ON UPDATE #{action.upcase})"
            else
              raise DatabaseError, "Unsupported ON UPDATE action: #{action}"
            end
          end
        end
        true
      end

      def apply_referential_update!(table_name, old_row, new_row)
        return true if old_row == new_row

        @table_metadata.each do |child_table, child_metadata|
          (child_metadata[:constraints] || []).each do |raw_definition|
            definition = raw_definition.transform_keys(&:to_sym)
            next unless %w[foreign_key foreign key].include?(definition[:type].to_s.downcase)
            next unless definition[:reference_table].to_s == table_name.to_s

            child_columns = Array(definition[:columns]).map(&:to_sym)
            parent_columns = Array(definition[:reference_columns] || :id).map(&:to_sym)
            next unless parent_columns.any? { |column| old_row[column] != new_row[column] }
            child_rows = select_rows(child_table, child_metadata[:columns], visibility_check: false)
            matching_rows = child_rows.select do |child_row|
              child_columns.each_with_index.all? do |child_column, index|
                child_value = child_row[child_column] || child_row[child_column.to_s]
                parent_value = old_row[parent_columns[index]] || old_row[parent_columns[index].to_s]
                !child_value.nil? && child_value == parent_value
              end
            end
            next if matching_rows.empty?

            action = (definition[:on_update] || :restrict).to_s.downcase.tr("- ", "__")
            matching_rows.each do |child_row|
              child_row_id = child_row[:_row_id] || child_row["_row_id"]
              updates = case action
                        when "cascade"
                          child_columns.each_with_index.to_h { |column, index| [column, new_row[parent_columns[index]] || new_row[parent_columns[index].to_s]] }
                        when "set_null"
                          child_columns.to_h { |column| [column, nil] }
                        when "set_default"
                          child_columns.each_with_object({}) do |column, result|
                            metadata_column = child_metadata[:columns].find { |candidate| candidate.name.to_sym == column }
                            result[column] = metadata_column&.default
                          end
                        else
                          next
                        end
              update_row(child_table, child_row_id, updates, visibility_check: false)
            end
          end
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
        # Transaction IDs cross session/process boundaries in the persisted
        # visibility and MVCC stores. A per-engine counter can collide when
        # two sessions open the same database, so include a time/process
        # component and retain a local monotonic suffix for same-tick calls.
        @transaction_id_counter ||= 0
        @transaction_id_counter += 1
        @transaction_id_namespace ||= SecureRandom.random_number(1_000_000)
        ((Time.now.to_f * 1_000_000).to_i * 1_000_000_000) +
          (Process.pid * 1_000_000) + (@transaction_id_namespace * 1_000) +
          @transaction_id_counter
      end

      def load_table_metadata
        begin
          metadata_path = "#{@path}.metadata"
          if File.exist?(metadata_path)
            data = File.read(metadata_path)
            parsed = JSON.parse(data, symbolize_names: true)
            
            parsed[:tables]&.each do |table_name, table_data|
              @table_metadata[table_name] = {
                metadata_page: table_data[:metadata_page],
                data_page: table_data[:data_page],
                columns: table_data[:columns]&.map do |c|
                  options = {
                    null: c[:nullable],
                    primary_key: c[:primary_key] || false,
                    unique: c[:unique] || false,
                    default: c[:default]
                  }
                  Catalog::Column.new(c[:name], c[:type].respond_to?(:to_sym) ? c[:type].to_sym : c[:type], **options)
                end || [],
                column_count: table_data[:column_count] || 0,
                row_count: table_data[:row_count] || 0,
                constraints: table_data[:constraints] || [],
                created_at: Time.at(table_data[:created_at]),
                updated_at: Time.at(table_data[:updated_at])
              }
              @table_pages[table_name] = table_data[:pages] || []
            end
          end
        rescue => e
          warn "Failed to load table metadata: #{e.class} #{e.message}"
          # If loading fails, start fresh
          @table_metadata.clear
          @table_pages.clear
        end
      end

      def rewrite_table_metadata_page(table_name, metadata)
        page = Page.new(metadata[:metadata_page], @storage_manager.page_size)
        page.write(0, begin
          serialized = StorageLayout::TableMetadata.new
          serialized.table_id = metadata[:metadata_page]
          serialized.table_name = table_name.to_s
          serialized.column_count = metadata[:columns].size
          serialized.row_count = metadata[:row_count].to_i
          serialized.first_page = metadata[:data_page]
          serialized.last_page = (@table_pages[table_name] || [metadata[:data_page]]).last
          serialized.created_at = metadata[:created_at].to_i
          serialized.updated_at = metadata[:updated_at].to_i
          serialized.serialize
        end)
        metadata[:columns].each_with_index do |column, index|
          column_meta = StorageLayout::ColumnMetadata.new
          column_meta.column_id = index + 1
          column_meta.column_name = column.name
          column_meta.data_type = column.type_class
          column_meta.is_nullable = column.nullable?
          column_meta.is_primary_key = column.primary_key?
          column_meta.position = index
          column_meta.default = column.default if column.has_default?
          page.write(PageHeader::SIZE + index * 128, column_meta.serialize)
        end
        write_page(page)
      end

      def save_table_metadata
        begin
          data = {
            tables: {}
          }

          @table_metadata.each do |table_name, metadata|
            data[:tables][table_name] = {
              metadata_page: metadata[:metadata_page],
              data_page: metadata[:data_page],
              columns: metadata[:columns].map do |c|
                {
                  name: c.name,
                  type: c.type_class,
                  nullable: c.nullable?,
                  primary_key: c.primary_key?,
                  unique: c.unique?,
                  default: c.default
                }
              end,
              constraints: metadata[:constraints] || [],
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
