# frozen_string_literal: true

class CatalogController < ApplicationController
  def index
    @category = params[:category]
    @products = Product.active.in_category(@category).order(price_cents: :asc).limit(50)
    @featured = Product.active.order(stock: :desc).limit(8)
    @categories = Product.active.group(:category).count

    respond_to do |format|
      format.html
      format.json do
        render json: {
          products: @products.as_json(only: %i[id name sku category price_cents stock]),
          categories: @categories
        }
      end
    end
  end
end
