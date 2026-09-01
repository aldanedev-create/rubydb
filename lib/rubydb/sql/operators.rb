# frozen_string_literal: true

module RubyDB
  module SQL
    # SQL operator definitions
    module Operators
      # Operator precedence (higher = binds tighter)
      PRECEDENCE = {
        Token::Type::DOT => 18,
        Token::Type::LBRACKET => 18,
        Token::Type::TILDE => 17,
        Token::Type::STAR => 16,
        Token::Type::SLASH => 16,
        Token::Type::PERCENT => 16,
        Token::Type::PLUS => 15,
        Token::Type::MINUS => 15,
        Token::Type::AMPERSAND => 14,
        Token::Type::PIPE => 13,
        Token::Type::CARET => 12,
        Token::Type::LT => 11,
        Token::Type::LTE => 11,
        Token::Type::GT => 11,
        Token::Type::GTE => 11,
        Token::Type::EQ => 10,
        Token::Type::NE => 10,
        Token::Type::LIKE => 9,
        Token::Type::ILIKE => 9,
        Token::Type::NOT => 8,
        Token::Type::AND => 7,
        Token::Type::OR => 6,
        Token::Type::BETWEEN => 5,
        Token::Type::IN => 5,
        Token::Type::IS => 5
      }.freeze

      # Operator associativity: :left, :right, or :nonassoc
      ASSOCIATIVITY = {
        Token::Type::DOT => :left,
        Token::Type::LBRACKET => :left,
        Token::Type::TILDE => :right,
        Token::Type::STAR => :left,
        Token::Type::SLASH => :left,
        Token::Type::PERCENT => :left,
        Token::Type::PLUS => :left,
        Token::Type::MINUS => :left,
        Token::Type::AMPERSAND => :left,
        Token::Type::PIPE => :left,
        Token::Type::CARET => :left,
        Token::Type::LT => :nonassoc,
        Token::Type::LTE => :nonassoc,
        Token::Type::GT => :nonassoc,
        Token::Type::GTE => :nonassoc,
        Token::Type::EQ => :nonassoc,
        Token::Type::NE => :nonassoc,
        Token::Type::LIKE => :nonassoc,
        Token::Type::ILIKE => :nonassoc,
        Token::Type::NOT => :right,
        Token::Type::AND => :left,
        Token::Type::OR => :left,
        Token::Type::BETWEEN => :nonassoc,
        Token::Type::IN => :nonassoc,
        Token::Type::IS => :nonassoc
      }.freeze

      def self.precedence(token_type)
        PRECEDENCE[token_type] || 0
      end

      def self.associativity(token_type)
        ASSOCIATIVITY[token_type] || :left
      end

      def self.comparison?(token_type)
        [Token::Type::EQ, Token::Type::NE, Token::Type::LT,
         Token::Type::LTE, Token::Type::GT, Token::Type::GTE,
         Token::Type::LIKE, Token::Type::ILIKE, Token::Type::BETWEEN,
         Token::Type::IN, Token::Type::IS].include?(token_type)
      end

      def self.logical?(token_type)
        [Token::Type::AND, Token::Type::OR, Token::Type::NOT].include?(token_type)
      end

      def self.arithmetic?(token_type)
        [Token::Type::PLUS, Token::Type::MINUS, Token::Type::STAR,
         Token::Type::SLASH, Token::Type::PERCENT].include?(token_type)
      end

      def self.bitwise?(token_type)
        [Token::Type::AMPERSAND, Token::Type::PIPE,
         Token::Type::CARET, Token::Type::TILDE].include?(token_type)
      end

      def self.unary?(token_type)
        [Token::Type::PLUS, Token::Type::MINUS, Token::Type::TILDE,
         Token::Type::NOT].include?(token_type)
      end
    end
  end
end