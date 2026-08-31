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
    rescue StandardError
      # Drop the (possibly dead) port so a long-running caller - e.g. a
      # daemon that outlives a USB adapter being unplugged/replugged - will
      # attempt a fresh #open on the next write, rather than repeatedly
      # failing against a stale handle.
      close
      raise
    end

    def close
      @port&.close
    rescue StandardError
      # Already broken; nothing sensible to do with a close error here.
    ensure
      @port = nil
    end

    # True once #open (or a successful #write) has established a port.
    # Note this doesn't guarantee the underlying device is still present -
    # only that we haven't detected it being gone yet (see #write).
    def connected?
      !@port.nil?
    end
  end
end
