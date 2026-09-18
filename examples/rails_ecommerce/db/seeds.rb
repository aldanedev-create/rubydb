# frozen_string_literal: true

random = Random.new(Integer(ENV.fetch("RUBYDB_SEED_SEED", "20260918"), 10))
product_count = Integer(ENV.fetch("RUBYDB_PRODUCTS", "250"), 10)
customer_count = Integer(ENV.fetch("RUBYDB_CUSTOMERS", "50"), 10)
order_count = Integer(ENV.fetch("RUBYDB_ORDERS", "200"), 10)
categories = %w[books home audio outdoor]

puts "Seeding #{product_count} products, #{customer_count} customers, and #{order_count} orders..."

ApplicationRecord.transaction do
  OrderItem.delete_all
  Order.delete_all
  Customer.delete_all
  Product.delete_all

  products = product_count.times.map do |index|
    Product.create!(
      name: "RubyDB Product #{index + 1}",
      sku: format("SKU-%06d", index + 1),
      category: categories[index % categories.length],
      price_cents: 500 + random.rand(50_000),
      stock: 100 + random.rand(900),
      active: (index % 17 != 0)
    )
  end

  customers = customer_count.times.map do |index|
    Customer.create!(name: "Customer #{index + 1}", email: "customer-#{index + 1}@example.test")
  end

  order_count.times do |index|
    selected_products = products.sample(1 + random.rand(3), random: random)
    items = selected_products.map do |product|
      quantity = 1 + random.rand(3)
      [product, quantity]
    end
    total_cents = items.sum { |product, quantity| product.price_cents * quantity }

    order = Order.create!(
      customer: customers[index % customers.length],
      status: %w[pending paid shipped cancelled][index % 4],
      total_cents: total_cents
    )
    items.each do |product, quantity|
      OrderItem.create!(order: order, product: product, quantity: quantity, unit_price_cents: product.price_cents)
    end
  end
end

puts "Seed complete: #{Product.count} products, #{Customer.count} customers, #{Order.count} orders, #{OrderItem.count} items."
