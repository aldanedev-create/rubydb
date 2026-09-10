# frozen_string_literal: true

require "strscan"
require_relative "../errors/error"
require_relative "../errors/parser_error"

module RubyDB
  module SQL
    # SQL Lexer - converts SQL text into tokens
    class Lexer
      attr_reader :tokens, :current_position

      def initialize(text)
        @text = text
        @scanner = StringScanner.new(text)
        @tokens = []
        @current_position = {line: 1, column: 1}
        @line_start = 0
        @current_position[:line] = 1
        @current_position[:column] = 1
      end

      def tokenize
        @tokens = []
        until @scanner.eos?
          skip_whitespace
          break if @scanner.eos?

          token = scan_token
          @tokens << token if token
        end
        @tokens << Token.new(Token::Type::EOF, line: @current_position[:line], column: @current_position[:column])
        @tokens
      end

      private

      def skip_whitespace
        loop do
          if @scanner.scan(/\s+/)
            update_position($&)
          elsif @scanner.scan(/--[^\n]*/)
            update_position($&)
            next
          elsif @scanner.scan(/\/\*.*?\*\//m)
            update_position($&)
            next
          else
            break
          end
        end
      end

      def scan_token
        pos = {line: @current_position[:line], column: @current_position[:column]}

        if @scanner.scan(/[a-zA-Z_][a-zA-Z0-9_]*/)
          word = @scanner.matched.upcase
          update_position($&)
          if Keywords.keyword?(word)
            Token.new(Keywords.token_type(word), word, **pos)
          else
            Token.new(Token::Type::IDENTIFIER, @scanner.matched, **pos)
          end

        elsif @scanner.scan(/'(?:''|[^'])*'/)
          update_position($&)
          Token.new(Token::Type::STRING, @scanner.matched[1..-2].gsub("''", "'"), **pos)

        elsif @scanner.scan(/"[^"]*"/)
          update_position($&)
          Token.new(Token::Type::IDENTIFIER, @scanner.matched[1..-2], **pos)

        elsif @scanner.scan(/`[^`]*`/)
          update_position($&)
          Token.new(Token::Type::IDENTIFIER, @scanner.matched[1..-2], **pos)

        elsif @scanner.scan(/\d+\.\d+/)
          update_position($&)
          Token.new(Token::Type::NUMBER, @scanner.matched.to_f, **pos)

        elsif @scanner.scan(/\d+/)
          update_position($&)
          Token.new(Token::Type::NUMBER, @scanner.matched.to_i, **pos)

        elsif @scanner.scan("?")
          update_position($&)
          Token.new(Token::Type::PARAMETER, nil, **pos)

        elsif @scanner.scan(/\$\d+/)
          update_position($&)
          Token.new(Token::Type::PARAMETER, @scanner.matched[1..].to_i, **pos)

        elsif @scanner.scan("<=")
          update_position($&)
          Token.new(Token::Type::LTE, "<=", **pos)

        elsif @scanner.scan(">=")
          update_position($&)
          Token.new(Token::Type::GTE, ">=", **pos)

        elsif @scanner.scan(/!=|<>/)
          update_position($&)
          Token.new(Token::Type::NE, @scanner.matched, **pos)

        elsif @scanner.scan("=")
          update_position($&)
          Token.new(Token::Type::EQ, "=", **pos)

        elsif @scanner.scan("<")
          update_position($&)
          Token.new(Token::Type::LT, "<", **pos)

        elsif @scanner.scan(">")
          update_position($&)
          Token.new(Token::Type::GT, ">", **pos)

        elsif @scanner.scan("+")
          update_position($&)
          Token.new(Token::Type::PLUS, "+", **pos)

        elsif @scanner.scan("-")
          update_position($&)
          Token.new(Token::Type::MINUS, "-", **pos)

        elsif @scanner.scan("*")
          update_position($&)
          Token.new(Token::Type::STAR, "*", **pos)

        elsif @scanner.scan("/")
          update_position($&)
          Token.new(Token::Type::SLASH, "/", **pos)

        elsif @scanner.scan("%")
          update_position($&)
          Token.new(Token::Type::PERCENT, "%", **pos)

        elsif @scanner.scan("(")
          update_position($&)
          Token.new(Token::Type::LPAREN, "(", **pos)

        elsif @scanner.scan(")")
          update_position($&)
          Token.new(Token::Type::RPAREN, ")", **pos)

        elsif @scanner.scan(",")
          update_position($&)
          Token.new(Token::Type::COMMA, ",", **pos)

        elsif @scanner.scan(";")
          update_position($&)
          Token.new(Token::Type::SEMICOLON, ";", **pos)

        elsif @scanner.scan(".")
          update_position($&)
          Token.new(Token::Type::DOT, ".", **pos)

        elsif @scanner.scan("[")
          update_position($&)
          Token.new(Token::Type::LBRACKET, "[", **pos)

        elsif @scanner.scan("]")
          update_position($&)
          Token.new(Token::Type::RBRACKET, "]", **pos)

        elsif @scanner.scan("{")
          update_position($&)
          Token.new(Token::Type::LBRACE, "{", **pos)

        elsif @scanner.scan("}")
          update_position($&)
          Token.new(Token::Type::RBRACE, "}", **pos)

        elsif @scanner.scan("&")
          update_position($&)
          Token.new(Token::Type::AMPERSAND, "&", **pos)

        elsif @scanner.scan("|")
          update_position($&)
          Token.new(Token::Type::PIPE, "|", **pos)

        elsif @scanner.scan("^")
          update_position($&)
          Token.new(Token::Type::CARET, "^", **pos)

        elsif @scanner.scan("~")
          update_position($&)
          Token.new(Token::Type::TILDE, "~", **pos)

        else
          char = @scanner.getch
          update_position(char)
          raise RubyDB::ParserError, "Unexpected character #{char.inspect} at #{@current_position[:line]}:#{@current_position[:column]}"
        end
      end

      def update_position(text)
        text ||= @scanner.matched
        lines = text.count("\n")
        if lines > 0
          @current_position[:line] += lines
          @current_position[:column] = text.length - text.rindex("\n")
        else
          @current_position[:column] += text.length
        end
      end
    end
  end
end
