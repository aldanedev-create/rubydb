# frozen_string_literal: true

module RubyDB
  module Catalog
    # SystemCatalog - maintains internal system tables with real data
    # This is the PostgreSQL-style system catalog that tracks all database objects
    class SystemCatalog
      attr_reader :catalog, :system_tables, :oid_counter

      def initialize(catalog)
        @catalog = catalog
        @system_tables = {}
        @oid_counter = 1000  # Starting OID for system objects
        @type_oids = {}
        @rows = {}  # Actual data storage for system tables
        initialize_system_tables
        populate
      end

      def initialize_system_tables
        # pg_namespace - schemas
        @system_tables[:pg_namespace] = Table.new("pg_namespace")
        @system_tables[:pg_namespace].add_column(Column.new("oid", :integer, primary_key: true))
        @system_tables[:pg_namespace].add_column(Column.new("nspname", :text))
        @system_tables[:pg_namespace].add_column(Column.new("nspowner", :integer))
        @system_tables[:pg_namespace].add_column(Column.new("nspcreated", :timestamp))

        # pg_class - tables, views, indexes, sequences
        @system_tables[:pg_class] = Table.new("pg_class")
        @system_tables[:pg_class].add_column(Column.new("oid", :integer, primary_key: true))
        @system_tables[:pg_class].add_column(Column.new("relname", :text))
        @system_tables[:pg_class].add_column(Column.new("relnamespace", :integer))
        @system_tables[:pg_class].add_column(Column.new("relkind", :text))  # r=table, v=view, i=index, s=sequence, m=materialized
        @system_tables[:pg_class].add_column(Column.new("reltuples", :bigint))
        @system_tables[:pg_class].add_column(Column.new("relpages", :integer))
        @system_tables[:pg_class].add_column(Column.new("relowner", :integer))
        @system_tables[:pg_class].add_column(Column.new("relcreated", :timestamp))
        @system_tables[:pg_class].add_column(Column.new("relmodified", :timestamp))

        # pg_attribute - columns
        @system_tables[:pg_attribute] = Table.new("pg_attribute")
        @system_tables[:pg_attribute].add_column(Column.new("attrelid", :integer))
        @system_tables[:pg_attribute].add_column(Column.new("attname", :text))
        @system_tables[:pg_attribute].add_column(Column.new("atttypid", :integer))
        @system_tables[:pg_attribute].add_column(Column.new("attnum", :integer))
        @system_tables[:pg_attribute].add_column(Column.new("attlen", :integer))
        @system_tables[:pg_attribute].add_column(Column.new("attnotnull", :boolean))
        @system_tables[:pg_attribute].add_column(Column.new("atthasdef", :boolean))
        @system_tables[:pg_attribute].add_column(Column.new("attdefault", :text))
        @system_tables[:pg_attribute].add_column(Column.new("attisdropped", :boolean))

        # pg_type - data types
        @system_tables[:pg_type] = Table.new("pg_type")
        @system_tables[:pg_type].add_column(Column.new("oid", :integer, primary_key: true))
        @system_tables[:pg_type].add_column(Column.new("typname", :text))
        @system_tables[:pg_type].add_column(Column.new("typlen", :integer))
        @system_tables[:pg_type].add_column(Column.new("typtype", :text))  # b=base, c=composite, d=domain

        # pg_index - indexes
        @system_tables[:pg_index] = Table.new("pg_index")
        @system_tables[:pg_index].add_column(Column.new("indexrelid", :integer))
        @system_tables[:pg_index].add_column(Column.new("indrelid", :integer))
        @system_tables[:pg_index].add_column(Column.new("indisunique", :boolean))
        @system_tables[:pg_index].add_column(Column.new("indisprimary", :boolean))
        @system_tables[:pg_index].add_column(Column.new("indkey", :text))  # Array of column numbers
        @system_tables[:pg_index].add_column(Column.new("indpred", :text))  # Partial index predicate

        # pg_constraint - constraints
        @system_tables[:pg_constraint] = Table.new("pg_constraint")
        @system_tables[:pg_constraint].add_column(Column.new("oid", :integer, primary_key: true))
        @system_tables[:pg_constraint].add_column(Column.new("conname", :text))
        @system_tables[:pg_constraint].add_column(Column.new("contype", :text))  # p=primary, f=foreign, u=unique, c=check
        @system_tables[:pg_constraint].add_column(Column.new("conrelid", :integer))
        @system_tables[:pg_constraint].add_column(Column.new("confrelid", :integer))
        @system_tables[:pg_constraint].add_column(Column.new("conkey", :text))  # Array of column numbers
        @system_tables[:pg_constraint].add_column(Column.new("confkey", :text))  # Array of foreign column numbers
        @system_tables[:pg_constraint].add_column(Column.new("confdeltype", :text))  # a=no action, r=restrict, c=cascade
        @system_tables[:pg_constraint].add_column(Column.new("confupdtype", :text))
        @system_tables[:pg_constraint].add_column(Column.new("condeferrable", :boolean))
        @system_tables[:pg_constraint].add_column(Column.new("condeferred", :boolean))

        # pg_sequence - sequences
        @system_tables[:pg_sequence] = Table.new("pg_sequence")
        @system_tables[:pg_sequence].add_column(Column.new("seqrelid", :integer))
        @system_tables[:pg_sequence].add_column(Column.new("seqstart", :bigint))
        @system_tables[:pg_sequence].add_column(Column.new("seqincrement", :bigint))
        @system_tables[:pg_sequence].add_column(Column.new("seqmax", :bigint))
        @system_tables[:pg_sequence].add_column(Column.new("seqmin", :bigint))
        @system_tables[:pg_sequence].add_column(Column.new("seqcycle", :boolean))
        @system_tables[:pg_sequence].add_column(Column.new("seqcurrent", :bigint))

        # pg_view - views
        @system_tables[:pg_view] = Table.new("pg_view")
        @system_tables[:pg_view].add_column(Column.new("viewrelid", :integer))
        @system_tables[:pg_view].add_column(Column.new("viewdefinition", :text))
        @system_tables[:pg_view].add_column(Column.new("viewmaterialized", :boolean))

        # pg_trigger - triggers
        @system_tables[:pg_trigger] = Table.new("pg_trigger")
        @system_tables[:pg_trigger].add_column(Column.new("oid", :integer, primary_key: true))
        @system_tables[:pg_trigger].add_column(Column.new("tgname", :text))
        @system_tables[:pg_trigger].add_column(Column.new("tgrelid", :integer))
        @system_tables[:pg_trigger].add_column(Column.new("tgenabled", :boolean))
        @system_tables[:pg_trigger].add_column(Column.new("tgtype", :integer))  # Bitmask: 1=insert, 2=update, 4=delete
        @system_tables[:pg_trigger].add_column(Column.new("tgtiming", :integer))  # 1=before, 2=after, 3=instead_of
        @system_tables[:pg_trigger].add_column(Column.new("tgcondition", :text))
        @system_tables[:pg_trigger].add_column(Column.new("tgdefinition", :text))

        # pg_database - databases
        @system_tables[:pg_database] = Table.new("pg_database")
        @system_tables[:pg_database].add_column(Column.new("oid", :integer, primary_key: true))
        @system_tables[:pg_database].add_column(Column.new("datname", :text))
        @system_tables[:pg_database].add_column(Column.new("datowner", :integer))
        @system_tables[:pg_database].add_column(Column.new("datcreated", :timestamp))

        # pg_user - users (simplified)
        @system_tables[:pg_user] = Table.new("pg_user")
        @system_tables[:pg_user].add_column(Column.new("usename", :text, primary_key: true))
        @system_tables[:pg_user].add_column(Column.new("usesysid", :integer))
        @system_tables[:pg_user].add_column(Column.new("usecreatedb", :boolean))
        @system_tables[:pg_user].add_column(Column.new("usesuper", :boolean))

        # Initialize rows storage
        @system_tables.each_key do |name|
          @rows[name] = []
        end

        build_type_oids
      end

      def build_type_oids
        @type_oids = {
          integer: 20,
          bigint: 21,
          smallint: 22,
          float: 23,
          decimal: 24,
          boolean: 25,
          text: 26,
          varchar: 27,
          blob: 28,
          date: 29,
          time: 30,
          timestamp: 31,
          json: 32,
          uuid: 33,
          char: 34,
          numeric: 35,
          double_precision: 36,
          real: 37,
          serial: 38,
          bigserial: 39
        }
      end

      # Populate system tables from catalog
      def populate
        clear_all_tables

        # Populate pg_type with built-in types
        populate_types

        # Populate pg_database
        populate_databases

        # Populate pg_namespace
        populate_namespaces

        # Populate pg_user (default users)
        populate_users

        # Populate pg_class, pg_attribute, etc.
        populate_catalog_objects
      end

      def clear_all_tables
        @rows.each_value(&:clear)
        @system_tables.each_value { |t| t.row_count = 0 }
      end

      def populate_types
        @type_oids.each do |type_name, oid|
          row = {
            "oid" => oid,
            "typname" => type_name.to_s,
            "typlen" => type_size(type_name),
            "typtype" => "b"
          }
          insert_row(:pg_type, row)
        end
      end

      def type_size(type_name)
        case type_name
        when :integer, :serial then 4
        when :bigint, :bigserial then 8
        when :smallint then 2
        when :float, :double_precision, :real then 8
        when :boolean then 1
        when :date then 4
        when :timestamp, :time then 8
        when :char then 1
        else 0  # variable length
        end
      end

      def populate_databases
        @catalog.databases.each do |db_name, db|
          oid = next_oid
          row = {
            "oid" => oid,
            "datname" => db_name,
            "datowner" => 1,
            "datcreated" => db.created_at.iso8601
          }
          insert_row(:pg_database, row)
        end
      end

      def populate_namespaces
        # public schema
        row = {
          "oid" => next_oid,
          "nspname" => "public",
          "nspowner" => 1,
          "nspcreated" => Time.now.iso8601
        }
        insert_row(:pg_namespace, row)

        # information_schema
        row = {
          "oid" => next_oid,
          "nspname" => "information_schema",
          "nspowner" => 1,
          "nspcreated" => Time.now.iso8601
        }
        insert_row(:pg_namespace, row)

        # pg_catalog (self)
        row = {
          "oid" => next_oid,
          "nspname" => "pg_catalog",
          "nspowner" => 1,
          "nspcreated" => Time.now.iso8601
        }
        insert_row(:pg_namespace, row)
      end

      def populate_users
        # Default admin user
        row = {
          "usename" => "postgres",
          "usesysid" => 1,
          "usecreatedb" => true,
          "usesuper" => true
        }
        insert_row(:pg_user, row)

        # Default application user
        row = {
          "usename" => "rubydb",
          "usesysid" => 2,
          "usecreatedb" => true,
          "usesuper" => false
        }
        insert_row(:pg_user, row)
      end

      def populate_catalog_objects
        return unless @catalog.current_database

        db = @catalog.current_database

        # Populate tables
        db.tables.each do |table|
          sync_table(table)
        end

        # Populate sequences
        db.sequences.each do |seq|
          sync_sequence(seq)
        end

        # Populate views
        db.views.each do |view|
          sync_view(view)
        end

        # Populate triggers
        db.triggers.each do |trigger|
          sync_trigger(trigger)
        end
      end

      def sync_table(table)
        # Get namespace OID
        ns_oid = get_namespace_oid("public")
        oid = next_oid

        # Add to pg_class
        row = {
          "oid" => oid,
          "relname" => table.name,
          "relnamespace" => ns_oid,
          "relkind" => "r",
          "reltuples" => table.row_count || 0,
          "relpages" => table.storage_size || 0,
          "relowner" => 1,
          "relcreated" => table.created_at.iso8601,
          "relmodified" => table.modified_at.iso8601
        }
        insert_row(:pg_class, row)

        # Store the OID for reference
        table.instance_variable_set(:@system_oid, oid)

        # Add columns to pg_attribute
        table.columns.each_with_index do |col, idx|
          type_oid = @type_oids[col.type_class] || 0
          row = {
            "attrelid" => oid,
            "attname" => col.name,
            "atttypid" => type_oid,
            "attnum" => idx + 1,
            "attlen" => type_size(col.type_class),
            "attnotnull" => !col.nullable?,
            "atthasdef" => col.has_default?,
            "attdefault" => col.default.to_s,
            "attisdropped" => false
          }
          insert_row(:pg_attribute, row)
        end

        # Add constraints to pg_constraint
        table.constraints.each do |constraint|
          sync_constraint(constraint, oid)
        end

        # Add indexes to pg_index
        table.indexes.each do |index|
          sync_index(index, oid)
        end
      end

      def sync_constraint(constraint, rel_oid)
        constr_oid = next_oid

        base_row = {
          "oid" => constr_oid,
          "conname" => constraint.name,
          "conrelid" => rel_oid,
          "confrelid" => 0,
          "conkey" => "",
          "confkey" => "",
          "confdeltype" => "",
          "confupdtype" => "",
          "condeferrable" => false,
          "condeferred" => false
        }

        case constraint
        when PrimaryKeyConstraint
          row = base_row.merge(
            "contype" => "p",
            "conkey" => constraint.columns.join(",")
          )
        when ForeignKeyConstraint
          row = base_row.merge(
            "contype" => "f",
            "confrelid" => get_table_oid(constraint.reference_table),
            "conkey" => constraint.columns.join(","),
            "confkey" => constraint.reference_columns.join(","),
            "confdeltype" => map_delete_action(constraint.on_delete),
            "confupdtype" => map_update_action(constraint.on_update)
          )
        when UniqueConstraint
          row = base_row.merge(
            "contype" => "u",
            "conkey" => constraint.columns.join(",")
          )
        when CheckConstraint
          row = base_row.merge(
            "contype" => "c"
          )
        else
          return
        end

        insert_row(:pg_constraint, row)
      end

      def sync_index(index, rel_oid)
        # Create index entry in pg_class
        idx_oid = next_oid
        ns_oid = get_namespace_oid("public")

        row = {
          "oid" => idx_oid,
          "relname" => index.name,
          "relnamespace" => ns_oid,
          "relkind" => "i",
          "reltuples" => 0,
          "relpages" => 0,
          "relowner" => 1,
          "relcreated" => index.created_at.iso8601,
          "relmodified" => index.modified_at.iso8601
        }
        insert_row(:pg_class, row)

        # Get column positions from pg_attribute
        column_numbers = index.columns.map do |col_name|
          # Find the column position
          attrs = query(:pg_attribute, attrelid: rel_oid, attname: col_name)
          if attrs.any?
            attrs.first["attnum"]
          else
            0
          end
        end

        # Add to pg_index
        row = {
          "indexrelid" => idx_oid,
          "indrelid" => rel_oid,
          "indisunique" => index.unique,
          "indisprimary" => false,
          "indkey" => column_numbers.join(","),
          "indpred" => index.options[:where] || ""
        }
        insert_row(:pg_index, row)
      end

      def sync_sequence(seq)
        ns_oid = get_namespace_oid("public")
        oid = next_oid

        # Add to pg_class
        row = {
          "oid" => oid,
          "relname" => seq.name,
          "relnamespace" => ns_oid,
          "relkind" => "s",
          "reltuples" => 0,
          "relpages" => 0,
          "relowner" => 1,
          "relcreated" => seq.created_at.iso8601,
          "relmodified" => seq.modified_at.iso8601
        }
        insert_row(:pg_class, row)

        # Add to pg_sequence
        row = {
          "seqrelid" => oid,
          "seqstart" => seq.start_value,
          "seqincrement" => seq.increment,
          "seqmax" => seq.max_value,
          "seqmin" => seq.min_value,
          "seqcycle" => seq.cycle,
          "seqcurrent" => seq.current_value
        }
        insert_row(:pg_sequence, row)
      end

      def sync_view(view)
        ns_oid = get_namespace_oid("public")
        oid = next_oid

        # Add to pg_class
        row = {
          "oid" => oid,
          "relname" => view.name,
          "relnamespace" => ns_oid,
          "relkind" => view.materialized ? "m" : "v",
          "reltuples" => 0,
          "relpages" => 0,
          "relowner" => 1,
          "relcreated" => view.created_at.iso8601,
          "relmodified" => view.modified_at.iso8601
        }
        insert_row(:pg_class, row)

        # Add to pg_view
        row = {
          "viewrelid" => oid,
          "viewdefinition" => view.query,
          "viewmaterialized" => view.materialized
        }
        insert_row(:pg_view, row)
      end

      def sync_trigger(trigger)
        oid = next_oid
        table_oid = get_table_oid(trigger.table_name)

        # Convert event types to bitmask
        event_bitmask = 0
        event_bitmask |= 1 if trigger.on_insert?
        event_bitmask |= 2 if trigger.on_update?
        event_bitmask |= 4 if trigger.on_delete?

        # Convert timing
        timing_value = case trigger.timing
        when :before then 1
        when :after then 2
        when :instead_of then 3
        else 2
        end

        row = {
          "oid" => oid,
          "tgname" => trigger.name,
          "tgrelid" => table_oid || 0,
          "tgenabled" => trigger.enabled,
          "tgtype" => event_bitmask,
          "tgtiming" => timing_value,
          "tgcondition" => trigger.condition || "",
          "tgdefinition" => trigger.definition
        }
        insert_row(:pg_trigger, row)
      end

      # Helper methods

      def insert_row(table_name, row_data)
        table = @system_tables[table_name]
        return unless table

        table.row_count += 1
        @rows[table_name] ||= []
        @rows[table_name] << row_data
      end

      def next_oid
        @oid_counter += 1
        @oid_counter
      end

      def get_namespace_oid(name)
        rows = @rows[:pg_namespace] || []
        row = rows.find { |r| r["nspname"] == name }
        row ? row["oid"] : 1
      end

      def get_table_oid(name)
        rows = @rows[:pg_class] || []
        row = rows.find { |r| r["relname"] == name && r["relkind"] == "r" }
        row ? row["oid"] : 0
      end

      def map_delete_action(action)
        case action&.to_s&.upcase
        when "CASCADE" then "c"
        when "RESTRICT" then "r"
        when "SET NULL" then "n"
        when "SET DEFAULT" then "d"
        else "a"
        end
      end

      def map_update_action(action)
        case action&.to_s&.upcase
        when "CASCADE" then "c"
        when "RESTRICT" then "r"
        when "SET NULL" then "n"
        when "SET DEFAULT" then "d"
        else "a"
        end
      end

      # Query system tables

      def query(table_name, conditions = {})
        rows = @rows[table_name.to_sym] || []
        rows.select do |row|
          conditions.all? { |key, value| row[key.to_s] == value }
        end
      end

      def find_table_oid(table_name)
        result = query(:pg_class, relname: table_name.to_s, relkind: "r")
        result.first&.fetch("oid")
      end

      def find_index_oid(index_name)
        result = query(:pg_class, relname: index_name.to_s, relkind: "i")
        result.first&.fetch("oid")
      end

      def find_sequence_oid(sequence_name)
        result = query(:pg_class, relname: sequence_name.to_s, relkind: "s")
        result.first&.fetch("oid")
      end

      def find_view_oid(view_name)
        result = query(:pg_class, relname: view_name.to_s, relkind: ["v", "m"])
        result.first&.fetch("oid")
      end

      def find_columns_for_table(table_name)
        oid = find_table_oid(table_name)
        return [] unless oid

        query(:pg_attribute, attrelid: oid).reject { |r| r["attisdropped"] }
      end

      def find_constraints_for_table(table_name)
        oid = find_table_oid(table_name)
        return [] unless oid

        query(:pg_constraint, conrelid: oid)
      end

      def find_indexes_for_table(table_name)
        oid = find_table_oid(table_name)
        return [] unless oid

        query(:pg_index, indrelid: oid)
      end

      def find_triggers_for_table(table_name)
        oid = find_table_oid(table_name)
        return [] unless oid

        query(:pg_trigger, tgrelid: oid)
      end

      def find_tables_in_schema(schema_name = "public")
        ns_oid = get_namespace_oid(schema_name)
        query(:pg_class, relnamespace: ns_oid, relkind: "r")
      end

      def find_all_tables
        query(:pg_class, relkind: "r")
      end

      def table_exists?(table_name)
        !find_table_oid(table_name).nil?
      end

      def index_exists?(index_name)
        !find_index_oid(index_name).nil?
      end

      def column_exists?(table_name, column_name)
        oid = find_table_oid(table_name)
        return false unless oid

        query(:pg_attribute, attrelid: oid, attname: column_name).any?
      end

      def type_exists?(type_name)
        @type_oids.key?(type_name.to_sym)
      end

      def get_type_oid(type_name)
        @type_oids[type_name.to_sym]
      end

      # Serialization

      def serialize
        {
          oid_counter: @oid_counter,
          type_oids: @type_oids,
          tables: @rows.transform_values(&:dup)
        }
      end

      def self.deserialize(data, catalog)
        system_catalog = new(catalog)
        system_catalog.instance_variable_set(:@oid_counter, data[:oid_counter] || 1000)
        system_catalog.instance_variable_set(:@type_oids, data[:type_oids] || {})

        data[:tables].each do |name, rows|
          system_catalog.instance_variable_get(:@rows)[name.to_sym] = rows.dup
          table = system_catalog.system_tables[name.to_sym]
          table.row_count = rows.size if table
        end

        system_catalog
      end

      def to_s
        "SystemCatalog with #{@system_tables.size} system tables and #{total_rows} total rows"
      end

      def inspect
        to_s
      end

      private

      def total_rows
        @rows.values.sum(&:size)
      end
    end
  end
end