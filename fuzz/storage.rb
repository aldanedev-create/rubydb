# frozen_string_literal: true

require "fileutils"

module RubyDB
  module Fuzz
    # StorageFuzzer - Fuzz testing for storage engine
    class StorageFuzzer
      attr_reader :stats

      def initialize(config = {})
        @config = config
        @test_dir = config[:test_dir] || "tmp/fuzz_storage"
        @max_iterations = config[:max_iterations] || 5000
        @seed = config[:seed]
        @stats = {
          total_operations: 0,
          successful_ops: 0,
          failed_ops: 0,
          errors: 0,
          crashes: 0,
          edge_cases_found: [],
          operations_by_type: Hash.new(0),
          total_bytes_written: 0,
          total_bytes_read: 0
        }
        @lock = Mutex.new
        @engine = nil
        @page_operations = [:read, :write, :allocate, :free, :compact]
        @record_operations = [:insert, :update, :delete, :select]

        srand(@seed) if @seed

        # Setup test directory
        FileUtils.rm_rf(@test_dir) if Dir.exist?(@test_dir)
        FileUtils.mkdir_p(@test_dir)
      end

      def fuzz(iterations = @max_iterations)
        @lock.synchronize do
          # Initialize storage engine
          db_path = File.join(@test_dir, "fuzz.rdb")
          @engine = RubyDB::Storage::Engine.new(db_path, 
            page_size: 8192,
            buffer_pool_size: 100
          )

          # Create test tables
          setup_test_tables

          iterations.times do |i|
            begin
              @stats[:total_operations] += 1

              # Choose random operation
              operation = choose_operation

              # Execute operation
              result = execute_operation(operation)

              if result[:success]
                @stats[:successful_ops] += 1
                @stats[:operations_by_type][operation[:type]] += 1
                @stats[:total_bytes_written] += result[:bytes_written] || 0
                @stats[:total_bytes_read] += result[:bytes_read] || 0
              else
                @stats[:failed_ops] += 1
                if result[:error] && result[:error].include?("crash")
                  @stats[:crashes] += 1
                  @stats[:edge_cases_found] << {
                    operation: operation,
                    error: result[:error],
                    iteration: i
                  }
                end
              end

            rescue => e
              @stats[:errors] += 1
              @stats[:crashes] += 1
              @stats[:edge_cases_found] << {
                operation: operation,
                error: e.message,
                backtrace: e.backtrace,
                iteration: i
              }
            end

            # Progress reporting
            if i % 100 == 0
              print_progress(i, iterations)
            end
          end

          # Cleanup
          @engine.close if @engine
          FileUtils.rm_rf(@test_dir) if Dir.exist?(@test_dir)

          @stats
        end
      end

      def choose_operation
        # Weighted random selection
        rand_num = rand

        if rand_num < 0.2
          { type: :page_read, page: rand(0..50) }
        elsif rand_num < 0.35
          { type: :page_write, page: rand(0..50) }
        elsif rand_num < 0.45
          { type: :page_allocate }
        elsif rand_num < 0.50
          { type: :page_free, page: rand(1..50) }
        elsif rand_num < 0.55
          { type: :page_compact, page: rand(1..50) }
        elsif rand_num < 0.65
          { type: :record_insert, table: ["fuzz_users", "fuzz_orders", "fuzz_products"].sample }
        elsif rand_num < 0.75
          { type: :record_update, table: ["fuzz_users", "fuzz_orders", "fuzz_products"].sample, row_id: rand(1..100) }
        elsif rand_num < 0.85
          { type: :record_delete, table: ["fuzz_users", "fuzz_orders", "fuzz_products"].sample, row_id: rand(1..100) }
        elsif rand_num < 0.95
          { type: :record_select, table: ["fuzz_users", "fuzz_orders", "fuzz_products"].sample }
        else
          { type: :flush }
        end
      end

      def execute_operation(operation)
        case operation[:type]
        when :page_read
          execute_page_read(operation[:page])
        when :page_write
          execute_page_write(operation[:page])
        when :page_allocate
          execute_page_allocate
        when :page_free
          execute_page_free(operation[:page])
        when :page_compact
          execute_page_compact(operation[:page])
        when :record_insert
          execute_record_insert(operation[:table])
        when :record_update
          execute_record_update(operation[:table], operation[:row_id])
        when :record_delete
          execute_record_delete(operation[:table], operation[:row_id])
        when :record_select
          execute_record_select(operation[:table])
        when :flush
          execute_flush
        else
          { success: false, error: "Unknown operation" }
        end
      end

      def execute_page_read(page)
        page_obj = @engine.read_page(page)
        { success: true, page: page_obj, bytes_read: page_obj.size }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_page_write(page)
        # Write random data to page
        page_obj = @engine.read_page(page)
        random_data = SecureRandom.random_bytes(page_obj.size)
        page_obj.write(0, random_data)
        @engine.write_page(page_obj)
        { success: true, bytes_written: page_obj.size }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_page_allocate
        page = @engine.allocate_page(rand(0..6))
        { success: true, page: page }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_page_free(page)
        @engine.free_page(page)
        { success: true }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_page_compact(page)
        result = @engine.page_allocator.compact_page(page)
        { success: true, result: result }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_record_insert(table)
        columns = get_table_columns(table)
        values = generate_record_values(table)
        @engine.insert_row(table, columns, values)
        { success: true, bytes_written: values.to_s.bytesize }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_record_update(table, row_id)
        columns = get_table_columns(table)
        values = generate_record_values(table)
        @engine.update_row(table, row_id, values)
        { success: true, bytes_written: values.to_s.bytesize }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_record_delete(table, row_id)
        @engine.delete_row(table, row_id)
        { success: true }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_record_select(table)
        columns = get_table_columns(table)
        rows = @engine.select_rows(table, columns)
        { success: true, rows: rows.size, bytes_read: rows.to_s.bytesize }
      rescue => e
        { success: false, error: e.message }
      end

      def execute_flush
        @engine.flush
        { success: true }
      rescue => e
        { success: false, error: e.message }
      end

      def get_table_columns(table)
        case table
        when "fuzz_users"
          [RubyDB::Catalog::Column.new("id", :integer, primary_key: true),
           RubyDB::Catalog::Column.new("name", :text),
           RubyDB::Catalog::Column.new("age", :integer),
           RubyDB::Catalog::Column.new("email", :text)]
        when "fuzz_orders"
          [RubyDB::Catalog::Column.new("id", :integer, primary_key: true),
           RubyDB::Catalog::Column.new("user_id", :integer),
           RubyDB::Catalog::Column.new("product_id", :integer),
           RubyDB::Catalog::Column.new("quantity", :integer),
           RubyDB::Catalog::Column.new("price", :decimal)]
        when "fuzz_products"
          [RubyDB::Catalog::Column.new("id", :integer, primary_key: true),
           RubyDB::Catalog::Column.new("name", :text),
           RubyDB::Catalog::Column.new("price", :decimal),
           RubyDB::Catalog::Column.new("category", :text)]
        else
          []
        end
      end

      def generate_record_values(table)
        case table
        when "fuzz_users"
          { "name" => "user_#{rand(1000)}", "age" => rand(18..65), "email" => "user#{rand(1000)}@test.com" }
        when "fuzz_orders"
          { "user_id" => rand(1..100), "product_id" => rand(1..50), "quantity" => rand(1..10), "price" => rand(10..1000) }
        when "fuzz_products"
          { "name" => "product_#{rand(1000)}", "price" => rand(10..1000), "category" => "cat_#{rand(1..5)}" }
        else
          {}
        end
      end

      def setup_test_tables
        begin
          @engine.execute("CREATE TABLE fuzz_users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, email TEXT)")
          @engine.execute("CREATE TABLE fuzz_orders (id INTEGER PRIMARY KEY, user_id INTEGER, product_id INTEGER, quantity INTEGER, price DECIMAL)")
          @engine.execute("CREATE TABLE fuzz_products (id INTEGER PRIMARY KEY, name TEXT, price DECIMAL, category TEXT)")
        rescue => e
          # Tables might already exist
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            test_dir: @test_dir,
            success_rate: @stats[:total_operations] > 0 ?
              (@stats[:successful_ops].to_f / @stats[:total_operations] * 100).round(2) : 0,
            avg_bytes_per_op: @stats[:total_operations] > 0 ?
              (@stats[:total_bytes_written] + @stats[:total_bytes_read]) / @stats[:total_operations] : 0
          })
        end
      end

      def print_progress(current, total)
        percent = (current.to_f / total * 100).round(1)
        bar_length = 40
        filled = (percent / 100 * bar_length).round
        bar = "[" + "=" * filled + " " * (bar_length - filled) + "]"

        print("\rStorage Fuzzing: #{bar} #{percent}% (#{current}/#{total})", nil, false)
        print("\n") if current == total - 1
      end
    end
  end
end