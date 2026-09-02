# frozen_string_literal: true

require "time"
require "json"
require "digest"

module RubyDB
  module Migrations
    # Migration - Represents a single database migration
    class Migration
      attr_reader :version, :name, :description, :up_operations
      attr_reader :down_operations, :created_at, :applied_at
      attr_reader :author, :dependencies, :checksum

      # Migration states
      STATE_PENDING = :pending
      STATE_APPLIED = :applied
      STATE_FAILED = :failed
      STATE_ROLLED_BACK = :rolled_back

      def initialize(version, name, options = {})
        @version = version
        @name = name
        @description = options[:description] || ""
        @up_operations = []
        @down_operations = []
        @created_at = Time.now
        @applied_at = nil
        @state = STATE_PENDING
        @author = options[:author]
        @dependencies = options[:dependencies] || []
        @checksum = nil
        @metadata = options[:metadata] || {}
      end

      def up(&block)
        if block_given?
          @up_operations << block
        end
        self
      end

      def down(&block)
        if block_given?
          @down_operations << block
        end
        self
      end

      def apply_up(engine)
        @up_operations.each do |operation|
          operation.call(engine)
        end
        @state = STATE_APPLIED
        @applied_at = Time.now
        calculate_checksum
      end

      def apply_down(engine)
        @down_operations.reverse_each do |operation|
          operation.call(engine)
        end
        @state = STATE_ROLLED_BACK
      end

      def applied?
        @state == STATE_APPLIED
      end

      def pending?
        @state == STATE_PENDING
      end

      def failed?
        @state == STATE_FAILED
      end

      def rolled_back?
        @state == STATE_ROLLED_BACK
      end

      def mark_failed
        @state = STATE_FAILED
      end

      def to_sql
        recorder = SQLRecorder.new
        @up_operations.each { |operation| operation.call(recorder) }
        recorder.to_sql
      end

      def to_hash
        {
          version: @version,
          name: @name,
          description: @description,
          created_at: @created_at.iso8601,
          applied_at: @applied_at&.iso8601,
          state: @state,
          author: @author,
          dependencies: @dependencies,
          checksum: @checksum,
          metadata: @metadata,
          up_operations_count: @up_operations.size,
          down_operations_count: @down_operations.size
        }
      end

      def to_json
        JSON.generate(to_hash)
      end

      def self.from_json(json_data)
        data = JSON.parse(json_data, symbolize_names: true)
        migration = new(data[:version], data[:name],
          description: data[:description],
          author: data[:author],
          dependencies: data[:dependencies] || [],
          metadata: data[:metadata] || {}
        )
        migration.instance_variable_set(:@created_at, Time.parse(data[:created_at]))
        migration.instance_variable_set(:@applied_at, Time.parse(data[:applied_at])) if data[:applied_at]
        migration.instance_variable_set(:@state, data[:state].to_sym)
        migration.instance_variable_set(:@checksum, data[:checksum])
        migration
      end

      def inspect
        "#<Migration version=#{@version} name=#{@name} state=#{@state}>"
      end

      private

      class SQLRecorder
        def initialize
          @statements = []
        end

        def create_table(name, options = {})
          columns = []
          builder = Object.new
          builder.define_singleton_method(:column) do |column_name, type, **column_options|
            columns << [column_name, type, column_options]
          end
          yield builder if block_given?
          definitions = columns.map { |column_name, type, column_options| column_sql(column_name, type, column_options) }
          statement = +"CREATE TABLE"
          statement << " IF NOT EXISTS" if options[:if_not_exists]
          statement << " #{identifier(name)} (#{definitions.join(', ')})"
          @statements << "#{statement};"
        end

        def drop_table(name, options = {})
          statement = "DROP TABLE"
          statement << " IF EXISTS" if options[:if_exists]
          statement << " #{identifier(name)}"
          statement << " CASCADE" if options[:cascade]
          @statements << "#{statement};"
        end

        def add_column(table, name, type, options = {})
          @statements << "ALTER TABLE #{identifier(table)} ADD COLUMN #{column_sql(name, type, options)};"
        end

        def remove_column(table, name, _options = {})
          @statements << "ALTER TABLE #{identifier(table)} DROP COLUMN #{identifier(name)};"
        end

        def change_column(table, name, type, _options = {})
          @statements << "ALTER TABLE #{identifier(table)} ALTER COLUMN #{identifier(name)} TYPE #{type_name(type)};"
        end

        def rename_column(table, old_name, new_name)
          @statements << "ALTER TABLE #{identifier(table)} RENAME COLUMN #{identifier(old_name)} TO #{identifier(new_name)};"
        end

        def add_index(table, columns, options = {})
          name = options[:name] || "idx_#{table}_#{Array(columns).join('_')}"
          unique = options[:unique] ? " UNIQUE" : ""
          @statements << "CREATE#{unique} INDEX #{identifier(name)} ON #{identifier(table)} (#{Array(columns).map { |column| identifier(column) }.join(', ')});"
        end

        def remove_index(table, options = {})
          name = options[:name] || "idx_#{table}_#{Array(options[:column] || options[:columns]).join('_')}"
          @statements << "DROP INDEX #{identifier(name)};"
        end

        def execute(sql)
          @statements << sql.to_s.sub(/;?\z/, ";")
        end

        def to_sql
          @statements.join("\n")
        end

        def method_missing(method, *_args, &_block)
          raise ArgumentError, "Cannot serialize migration operation '#{method}' to SQL"
        end

        def respond_to_missing?(_method, _include_private = false)
          false
        end

        private

        def column_sql(name, type, options)
          definition = [identifier(name), type_name(type)]
          definition << "PRIMARY KEY" if options[:primary_key]
          definition << "UNIQUE" if options[:unique] && !options[:primary_key]
          definition << "NOT NULL" if options[:null] == false
          definition << "DEFAULT #{literal(options[:default])}" if options.key?(:default)
          definition.join(" ")
        end

        def type_name(type)
          type.to_s.upcase
        end

        def identifier(value)
          "\"#{value.to_s.gsub('"', '""')}\""
        end

        def literal(value)
          case value
          when nil then "NULL"
          when Numeric then value.to_s
          when TrueClass then "TRUE"
          when FalseClass then "FALSE"
          else "'#{value.to_s.gsub("'", "''")}'"
          end
        end
      end

      def calculate_checksum
        data = @up_operations.map(&:to_s).join + @down_operations.map(&:to_s).join
        @checksum = Digest::SHA256.hexdigest(data)[0...16]
      end
    end
  end
end
