# frozen_string_literal: true

require_relative "../config/environment"

raise "products table is missing" unless ActiveRecord::Base.connection.table_exists?("products")
raise "customers table is missing" unless ActiveRecord::Base.connection.table_exists?("customers")

product = Product.active.order(:id).first
raise "seed the database before running the smoke test" unless product

catalog = Product.active.in_category(product.category).order(price_cents: :asc).limit(10).to_a
raise "catalog query returned no rows" if catalog.empty?

summary = Order.completed.group(:status).count
raise "grouped order query returned no rows" if summary.empty?

order = Order.includes(:customer, :order_items).order(id: :desc).first
raise "eager-loaded order query returned no rows" unless order&.customer && order&.order_items

puts "Rails + RubyDB commerce smoke test passed"
puts "products=#{Product.count} customers=#{Customer.count} orders=#{Order.count} items=#{OrderItem.count}"
puts "completed_orders=#{summary.inspect} latest_order=#{order.id}"
