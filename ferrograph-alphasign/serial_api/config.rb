# Configuration for the serial-api service, read from the environment.
# Defaults match XDF's own documented defaults (see the root README and
# docs/xdf-firmware-notes.md): 9600 8N1, broadcast address, all sign types.
#
# This service is the only thing that touches the serial port. It has no
# authentication of its own and is meant to stay bound to 127.0.0.1 -
# access control is the web-app's job (see web_app/).
module SerialApi
  module Config
    module_function

    def device
      ENV.fetch("SERIAL_DEVICE", "/dev/ttyUSB0")
    end

    def baud
      Integer(ENV.fetch("SERIAL_BAUD", "9600"))
    end

    def parity
      ENV.fetch("SERIAL_PARITY", "none")
    end

    def data_bits
      Integer(ENV.fetch("SERIAL_DATA_BITS", "8"))
    end

    def stop_bits
      Integer(ENV.fetch("SERIAL_STOP_BITS", "1"))
    end

    def address
      ENV.fetch("SERIAL_ADDRESS", AlphaSign::Protocol::BROADCAST_ADDRESS)
    end

    def type
      ENV.fetch("SERIAL_TYPE", AlphaSign::Protocol::TYPE_ALL)
    end

    def bind
      ENV.fetch("SERIAL_API_BIND", "127.0.0.1")
    end

    def port
      Integer(ENV.fetch("SERIAL_API_PORT", "4568"))
    end
  end
end
