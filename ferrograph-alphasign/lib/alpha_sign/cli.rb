require "optparse"

module AlphaSign
  class CLI
    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      command = argv.shift
      case command
      when "send" then cmd_send(argv)
      when "clear" then cmd_clear(argv)
      when "raw" then cmd_raw(argv)
      when "read" then cmd_read(argv)
      when "list-modes" then list(Modes::NAMES)
      when "list-colors" then list(Colors::NAMES)
      when "list-positions" then list(Positions::NAMES)
      when "list-fonts" then list(CharSets::NAMES)
      when "-h", "--help", nil then print_help
      else
        warn "Unknown command: #{command.inspect}\n\n"
        print_help
        exit 1
      end
    rescue ArgumentError, OptionParser::ParseError => e
      warn "Error: #{e.message}"
      exit 1
    end

    private

    def default_options
      {
        baud: 9600,
        parity: "none",
        data_bits: 8,
        stop_bits: 1,
        address: Protocol::BROADCAST_ADDRESS,
        type: Protocol::TYPE_ALL
      }
    end

    def common_options(parser, opts)
      parser.on("-d", "--device DEVICE", "Serial device, e.g. /dev/ttyUSB0, /dev/tty.usbserial-XXXX, COM3") { |v| opts[:device] = v }
      parser.on("-b", "--baud BAUD", Integer,
                "Baud rate (default: #{opts[:baud]}). XDF DIP switches offer 2400/4800/9600/19200/38400.") { |v| opts[:baud] = v }
      parser.on("--parity PARITY", %w[none even odd],
                "Parity: none|even|odd (default: #{opts[:parity]}). XDF always requires 'none' - only change this for non-XDF Alpha hardware.") { |v| opts[:parity] = v }
      parser.on("--data-bits N", Integer,
                "Data bits: 7 or 8 (default: #{opts[:data_bits]}). XDF always requires 8.") { |v| opts[:data_bits] = v }
      parser.on("--stop-bits N", Integer,
                "Stop bits: 1 or 2 (default: #{opts[:stop_bits]}). XDF always requires 1.") { |v| opts[:stop_bits] = v }
      parser.on("-a", "--address ADDR", "Sign address, 2 characters (default: #{opts[:address]} = broadcast)") { |v| opts[:address] = v }
      parser.on("-t", "--type TYPE",
                "Sign type code, 1 character (default: #{opts[:type]} = all types). 'A' = XDF/ADF signs only, 'a' = Aurora 63-specific.") { |v| opts[:type] = v }
      parser.on("--dry-run", "Build and print the packet without opening the serial port") { opts[:dry_run] = true }
      parser.on("-v", "--verbose", "Print the packet bytes that are sent") { opts[:verbose] = true }
    end

    def cmd_send(argv)
      opts = default_options.merge(label: "A", mode: "hold", position: "middle")
      parser = OptionParser.new do |p|
        p.banner = "Usage: alphasign send [options] MESSAGE"
        common_options(p, opts)
        p.on("-l", "--label LABEL", "TEXT file label (default: #{opts[:label]})") { |v| opts[:label] = v }
        p.on("-m", "--mode MODE", "Display mode (default: #{opts[:mode]}). See `alphasign list-modes`.") { |v| opts[:mode] = v }
        p.on("-p", "--position POSITION", "Display position (default: #{opts[:position]}). See `alphasign list-positions`.") { |v| opts[:position] = v }
        p.on("-s", "--speed SPEED", Integer, "Speed 1 (slowest) to 5 (fastest)") { |v| opts[:speed] = v }
        p.on("-c", "--color COLOR", "Named color. See `alphasign list-colors`.") { |v| opts[:color] = v }
        p.on("-f", "--font FONT", "Named character set/font. See `alphasign list-fonts`.") { |v| opts[:font] = v }
        p.on("--priority", "Show as priority text, overriding all other messages") { opts[:priority] = true }
      end
      parser.parse!(argv)

      message = argv.join(" ")
      if message.empty?
        warn parser.help
        exit 1
      end

      prefix = +""
      prefix << Speeds.lookup(opts[:speed]) if opts[:speed]
      prefix << Colors.lookup(opts[:color]) if opts[:color]
      prefix << CharSets.lookup(opts[:font]) if opts[:font]

      text_file = TextFile.new(prefix + message,
                                label: opts[:label],
                                position: Positions.lookup(opts[:position]),
                                mode: Modes.lookup(opts[:mode]),
                                priority: opts[:priority])
      send_packet(text_file.to_packet(type: opts[:type], address: opts[:address]), opts)
    end

    def cmd_clear(argv)
      opts = default_options.merge(label: "A")
      parser = OptionParser.new do |p|
        p.banner = "Usage: alphasign clear [options]"
        common_options(p, opts)
        p.on("-l", "--label LABEL", "TEXT file label to clear (default: #{opts[:label]})") { |v| opts[:label] = v }
      end
      parser.parse!(argv)

      text_file = TextFile.new("", label: opts[:label])
      send_packet(text_file.to_packet(type: opts[:type], address: opts[:address]), opts)
    end

    def cmd_raw(argv)
      opts = default_options
      parser = OptionParser.new do |p|
        p.banner = "Usage: alphasign raw [options] COMMAND_CODE [DATA]\n" \
                   "  Sends COMMAND_CODE + DATA as the contents of a standard packet.\n" \
                   "  Useful for protocol commands this CLI doesn't wrap yet."
        common_options(p, opts)
      end
      parser.parse!(argv)

      command_code, data = argv
      if command_code.nil? || command_code.empty?
        warn parser.help
        exit 1
      end

      packet = Packet.new("#{command_code}#{data}", type: opts[:type], address: opts[:address])
      send_packet(packet, opts)
    end

    def send_packet(packet, opts)
      $stderr.puts "Packet (#{packet.bytes.size} bytes): #{packet.to_hex}" if opts[:dry_run] || opts[:verbose]
      return if opts[:dry_run]

      unless opts[:device]
        warn "Error: --device is required (e.g. --device /dev/ttyUSB0)"
        exit 1
      end

      conn = SerialConnection.new(device: opts[:device], baud: opts[:baud], data_bits: opts[:data_bits],
                                   stop_bits: opts[:stop_bits], parity: opts[:parity])
      conn.open
      conn.write(packet)
      conn.close
      $stderr.puts "Sent." if opts[:verbose]
    end

    def list(names)
      names.keys.sort.each { |name| puts name }
    end

    # Sends a Read request and prints whatever the sign says back, raw
    # bytes included. The request formats for reads come from Alpha's
    # protocol manual rather than XDF's, so the hex is the point: it's the
    # evidence for what the sign actually replies, as against what this
    # library assumes it will.
    def cmd_read(argv)
      opts = default_options
      timeout = 5
      parser = OptionParser.new do |p|
        p.banner = "Usage: alphasign read [options] WHAT [LABEL]\n" \
                   "  WHAT is one of: config, dump, text, string, image, or a raw\n" \
                   "  command code. text/string/image take a single-character LABEL.\n" \
                   "  Prints the reply as hex and as printable text."
        p.on("--timeout SECONDS", Float, "How long to wait for a reply (default 5)") { |v| timeout = v }
        common_options(p, opts)
      end
      parser.parse!(argv)

      what, label = argv
      contents = read_request_for(what, label)
      if contents.nil?
        warn parser.help
        exit 1
      end

      packet = Packet.new(contents, type: opts[:type], address: opts[:address])
      if opts[:dry_run]
        puts packet.to_hex
        return
      end

      connection = SerialConnection.new(
        device: opts[:device], baud: opts[:baud], parity: opts[:parity],
        data_bits: opts[:data_bits], stop_bits: opts[:stop_bits]
      )
      response = connection.transact(packet, timeout: timeout)
      connection.close

      puts "request:  #{packet.to_hex}"
      if response.empty?
        puts "reply:    (nothing - the sign didn't answer within #{timeout}s)"
        exit 1
      end
      puts "reply:    #{response.to_hex}"
      puts "printable: #{response.to_printable}"
      puts "contents: #{response.contents.inspect}" if response.contents
      puts "checksum: #{response.checksum} (computed #{response.computed_checksum}, #{response.checksum_ok? ? 'ok' : 'MISMATCH'})" if response.checksum
    end

    def read_request_for(what, label)
      case what
      when "config" then "#{Protocol::READ_SPECIAL}#{Protocol::MEMORY_CONFIG}"
      when "dump" then "#{Protocol::READ_SPECIAL}%"
      when "text" then label && "#{Protocol::READ_TEXT}#{label}"
      when "string" then label && "#{Protocol::READ_STRING}#{label}"
      when "image" then label && "#{Protocol::READ_SMALL_DOTS}#{label}"
      when nil, "" then nil
      else "#{what}#{label}"
      end
    end

    def print_help
      puts <<~HELP
        alphasign - send messages to Alpha-protocol LED signs
        (e.g. a Ferrograph Aurora 63 running XDF firmware) over a serial port.

        Usage:
          alphasign send [options] MESSAGE
          alphasign clear [options]
          alphasign raw [options] COMMAND_CODE [DATA]
          alphasign read [options] WHAT [LABEL]
          alphasign list-modes
          alphasign list-colors
          alphasign list-positions
          alphasign list-fonts

        Examples:
          alphasign send --device /dev/ttyUSB0 "Hello, world!"
          alphasign send -d /dev/ttyUSB0 -m rotate -c red -s 3 "Sale ends Friday"
          alphasign send -d /dev/ttyUSB0 -m twinkle -c rainbow1 "Big news!"
          alphasign send -d /dev/ttyUSB0 -f large_standard "BIG TEXT"
          alphasign send -d /dev/ttyUSB0 --dry-run "test message"
          alphasign clear -d /dev/ttyUSB0
          alphasign read -d /dev/ttyUSB0 config
          alphasign read -d /dev/ttyUSB0 image Q

        Run `alphasign send --help` for the full list of message options.
      HELP
    end
  end
end
