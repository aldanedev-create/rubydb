# frozen_string_literal: true

module RubyDB
  module CLI
    module Commands
      # Accelerator - Inspect and verify the optional Go execution layer.
      class Accelerator
        def initialize(output, formatter)
          @output = output
          @formatter = formatter
        end

        def execute(args, options)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rubydb accelerator [options]"
            opts.on("--ping", "Start the accelerator and verify the protocol") do
              options[:ping] = true
            end
            opts.on("--mode MODE", %w[auto off required], "Override mode for this check") do |mode|
              options[:accelerator_mode] = mode
            end
            opts.on("--json", "Output JSON") do
              options[:json] = true
            end
            opts.on("-h", "--help", "Show help") do
              @output.puts opts
              exit(0)
            end
          end
          parser.parse!(args)

          configured_accelerator = RubyDB::Configuration::Config.instance.to_hash[:accelerator]
          config = if configured_accelerator.is_a?(Hash)
            configured_accelerator.to_h.dup
          else
            # RUBYDB_ACCELERATOR=off|auto|required is a shorthand environment
            # override. The environment parser may therefore replace the
            # nested accelerator hash with a string; normalize it back into
            # the client configuration instead of calling Hash#to_h on it.
            {mode: configured_accelerator.to_s}
          end
          config[:mode] = options[:accelerator_mode] if options[:accelerator_mode]
          client = RubyDB::Accelerator::Client.new(config)
          details = client.stats
          if options[:ping] && details[:available]
            details[:ping] = client.ping
          end
          details[:healthy] = if details[:mode] == "off"
            true
          elsif details[:available]
            !options[:ping] || details[:ping].is_a?(Hash)
          else
            details[:mode] != "required"
          end

          if options[:json]
            @output.json(details)
          else
            @output.puts "RubyDB Go accelerator"
            details.each { |key, value| @output.puts "  #{key}: #{value.inspect}" }
          end
          details[:healthy] ? 0 : 1
        rescue RubyDB::Accelerator::Error => error
          @output.error(error.message)
          1
        ensure
          client&.close
        end
      end
    end
  end
end
