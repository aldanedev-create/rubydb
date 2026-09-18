# frozen_string_literal: true

class OrdersController < ApplicationController
  def create
    product = Product.active.find(order_params[:product_id])
    quantity = Integer(order_params[:quantity], 10)
    raise ActiveRecord::RecordInvalid, product if quantity < 1 || quantity > product.stock

    customer = Customer.find_or_create_by!(email: order_params[:email]) do |record|
      record.name = order_params[:name]
    end

    Order.transaction do
      order = customer.orders.create!(status: "paid", total_cents: product.price_cents * quantity)
      order.order_items.create!(product: product, quantity: quantity, unit_price_cents: product.price_cents)
      product.update!(stock: product.stock - quantity)
    end

    redirect_to root_path, notice: "Order created"
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    redirect_to root_path, alert: "Order could not be created: #{error.message}"
  end

  private

  def order_params
    params.require(:order).permit(:product_id, :quantity, :name, :email)
  end
end
