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
      when "probe" then cmd_probe(argv)
      when "loopback" then cmd_loopback(argv)
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

    # Every command that opens the port goes through here, so a missing
    # --device is reported the same way each time. Without the check the
    # device reaches SerialPort.new as nil and surfaces as a bare "wrong
    # argument type (TypeError)" from inside the gem, which says nothing
    # about what the caller got wrong.
    def open_connection(opts)
      if opts[:device].nil? || opts[:device].to_s.empty?
        warn "Error: --device is required (e.g. --device /dev/ttyUSB0, " \
             "or --device /dev/tty.usbserial-XXXX on macOS)."
        warn "       Run `ls /dev/tty.usbserial-* /dev/ttyUSB*` to find yours."
        exit 1
      end

      SerialConnection.new(
        device: opts[:device], baud: opts[:baud], parity: opts[:parity],
        data_bits: opts[:data_bits], stop_bits: opts[:stop_bits]
      )
    end

    def send_packet(packet, opts)
      $stderr.puts "Packet (#{packet.bytes.size} bytes): #{packet.to_hex}" if opts[:dry_run] || opts[:verbose]
      return if opts[:dry_run]

      conn = open_connection(opts)
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

      connection = open_connection(opts)
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

    # Works out WHY a read request got no answer.
    #
    # A real Aurora 63 answered neither "F$" (Read Memory Configuration)
    # nor "JQ" (Read Small Dots) - just silence. The manual says that is
    # what happens to a request the sign doesn't recognise: "unrecognised
    # commands that are still correctly constructed will be ignored and
    # will not result in any error reporting". So silence is evidence about
    # the REQUEST, not proof the feature is missing - section 4 is titled
    # "Support for Serial Readback" and Appendix B marks 0x24 as
    # Write/Read.
    #
    # This sends several read requests whose replies mean different things,
    # so the answers separate the possibilities.
    def cmd_probe(argv)
      opts = default_options
      timeout = 5
      parser = OptionParser.new do |p|
        p.banner = "Usage: alphasign probe [options]\n" \
                   "  Sends a series of read requests and reports which the sign answers,\n" \
                   "  to work out whether read-back is unsupported, our request format is\n" \
                   "  wrong, or the adapter can't receive."
        p.on("--timeout SECONDS", Float, "How long to wait for each reply (default 5)") { |v| timeout = v }
        common_options(p, opts)
      end
      parser.parse!(argv)

      probes = [
        ["Read General Information (0x22)", "#{Protocol::READ_SPECIAL}\x22",
         "Appendix B lists this as Read-only, so it should always answer"],
        ["Read Special Function, deliberately bogus sub-code", "#{Protocol::READ_SPECIAL}~",
         "the manual says an unsupported sub-code gets a *** NOT SUPPORTED *** reply"],
        ["Read Memory Configuration (0x24)", "#{Protocol::READ_SPECIAL}#{Protocol::MEMORY_CONFIG}",
         "Appendix B marks 0x24 Write/Read"],
        ["Read Text file A", "#{Protocol::READ_TEXT}A",
         "section 5 says all Text, String and Dots files can be read back"],
        ["Read Serial Error Status (0x2A)", "#{Protocol::READ_SPECIAL}*",
         "Read-only in Appendix B, and short - a good canary"]
      ]

      connection = open_connection(opts)

      answered = []
      probes.each do |name, contents, why|
        packet = Packet.new(contents, type: opts[:type], address: opts[:address])
        response = connection.transact(packet, timeout: timeout)
        puts name
        puts "  why:      #{why}"
        puts "  request:  #{packet.to_hex}"
        if response.empty?
          puts "  reply:    (nothing)"
        else
          answered << name
          puts "  reply:    #{response.to_hex}"
          puts "  as text:  #{response.to_printable}"
        end
        puts
      end
      connection.close

      puts "-" * 60
      if answered.empty?
        puts "Nothing answered. That means one of:"
        puts "  1. the read command codes are wrong, so the sign is silently"
        puts "     ignoring every request (what the manual says it does with"
        puts "     commands it doesn't recognise), or"
        puts "  2. nothing the sign sends is reaching this computer."
        puts
        puts "Rule out (2) first, and it takes 30 seconds: short pins 2 and 3"
        puts "together on the DB9 and run"
        puts "  alphasign loopback -d #{opts[:device]}"
        puts "If that echoes, the cable can receive and the problem is (1)."
      else
        puts "#{answered.size} of #{probes.size} answered, so read-back works and this"
        puts "sign does support it. The requests that got nothing have the wrong"
        puts "format - send the replies above and they can be fixed."
      end
    end

    # Tests whether anything the sign sends could reach us at all, without
    # involving the sign: short pins 2 and 3 of the DB9 together and every
    # byte written comes straight back.
    #
    # Worth doing before blaming the protocol. Writing to the sign proves
    # only that PC->sign is wired; a cable with no return path behaves
    # exactly like a sign that never answers.
    def cmd_loopback(argv)
      opts = default_options
      parser = OptionParser.new do |p|
        p.banner = "Usage: alphasign loopback [options]\n" \
                   "  Short pins 2 and 3 of the DB9 together, then run this. It writes a\n" \
                   "  known pattern and reports whether it comes back - which tells you\n" \
                   "  whether the adapter can receive at all."
        common_options(p, opts)
      end
      parser.parse!(argv)

      # Said before the result, not after, because the result is worthless
      # if the loopback isn't in place - and "nothing came back" looks
      # identical whether the wiring is broken or the test wasn't set up.
      puts "This test needs the sign UNPLUGGED and DB9 pins 2 and 3 shorted"
      puts "together, so the adapter's own output feeds back into its input."
      puts "Run against the sign, it will always say nothing came back."
      puts

      pattern = "ALPHASIGN LOOPBACK 0123456789"
      connection = open_connection(opts)
      # Framed as a packet so the read stops at EOT rather than waiting out
      # the whole timeout.
      packet = Packet.new(pattern, type: opts[:type], address: opts[:address])
      response = connection.transact(packet, timeout: 3)
      connection.close

      puts "sent:     #{packet.to_hex}"
      if response.empty?
        puts "received: (nothing)"
        puts
        puts "This means one of:"
        puts "  1. pins 2 and 3 weren't actually shorted (or the jumper isn't"
        puts "     making contact) - by far the most common, so check that first;"
        puts "  2. the adapter or cable has no working receive path."
        puts
        puts "If a bare wire between 2 and 3 is awkward, a proper loopback plug"
        puts "bridges 2-3, 7-8 and 4-6 - worth trying if the simple short doesn't"
        puts "echo, in case hardware flow control is holding the transmitter off."
        puts
        puts "Only once this echoes is a silent sign evidence about the protocol."
        exit 1
      end

      puts "received: #{response.to_hex}"
      if response.raw.include?(pattern)
        puts
        puts "The pattern came back: the adapter can receive. So if the sign"
        puts "still answers nothing, the request format is what's wrong."
      else
        puts
        puts "Something came back, but not what was sent - suspect the baud rate"
        puts "or wiring rather than the protocol."
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
          alphasign probe [options]
          alphasign loopback [options]
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
          alphasign probe -d /dev/ttyUSB0        # why isn't the sign answering reads?
          alphasign loopback -d /dev/ttyUSB0     # can this cable receive at all?

        Run `alphasign send --help` for the full list of message options.
      HELP
    end
  end
end
