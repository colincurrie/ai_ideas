begin
  require "serialport"
rescue LoadError
  # Reported lazily in #open so commands like `list-modes` or `--dry-run`
  # work without the gem (and its native extension) installed.
end

module AlphaSign
  class SerialConnection
    PARITY = {
      "none" => 0, # SerialPort::NONE
      "even" => 1, # SerialPort::EVEN
      "odd" => 2   # SerialPort::ODD
    }.freeze

    def initialize(device:, baud: 9600, data_bits: 8, stop_bits: 1, parity: "none")
      raise ArgumentError, "unknown parity #{parity.inspect}; use one of #{PARITY.keys.join(', ')}" unless PARITY.key?(parity)

      @device = device
      @baud = baud
      @data_bits = data_bits
      @stop_bits = stop_bits
      @parity = parity
      @port = nil
    end

    def open
      unless defined?(SerialPort)
        raise LoadError, "the 'serialport' gem is required to talk to a real serial port. " \
                          "Run `bundle install` (see README.md) or `gem install serialport`."
      end

      @port = SerialPort.new(@device, @baud, @data_bits, @stop_bits, PARITY.fetch(@parity))
      @port.read_timeout = 1000
      self
    end

    def write(packet)
      open unless @port
      @port.write(packet.to_s)
      @port.flush
    end

    def close
      @port&.close
      @port = nil
    end
  end
end
