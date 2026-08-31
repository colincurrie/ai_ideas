# Raw control codes and command codes from the Alpha Sign Communications
# Protocol (AMS / Adaptive Micro Systems), the protocol implemented by the
# Ferrograph Aurora 63's XDF firmware.
module AlphaSign
  module Protocol
    # Control codes
    NUL = "\x00" # Null (wake-up padding)
    SOH = "\x01" # Start of Header
    STX = "\x02" # Start of Text (precedes the command code)
    ETX = "\x03" # End of Text
    EOT = "\x04" # End of Transmission
    ESC = "\x1B" # Escape (precedes display position/mode in a TEXT file)

    # A real RS232 link needs a handful of NUL bytes before <SOH> so the
    # sign's UART has time to sync on the start of a new packet.
    WAKEUP = NUL * 5

    # Command codes (the byte immediately after <STX>)
    WRITE_TEXT       = "A" # Write TEXT file
    READ_TEXT        = "B" # Read TEXT file
    WRITE_SPECIAL    = "E" # Write SPECIAL FUNCTION commands
    READ_SPECIAL     = "F" # Read SPECIAL FUNCTION commands
    WRITE_STRING     = "G" # Write STRING
    READ_STRING      = "H" # Read STRING
    WRITE_SMALL_DOTS = "I" # Write SMALL DOTS PICTURE file
    READ_SMALL_DOTS  = "J" # Read SMALL DOTS PICTURE file
    WRITE_RGB_DOTS   = "K" # Write RGB DOTS PICTURE file
    READ_RGB_DOTS    = "L" # Read RGB DOTS PICTURE file
    WRITE_LARGE_DOTS = "M" # Write LARGE DOTS PICTURE file
    READ_LARGE_DOTS  = "N" # Read LARGE DOTS PICTURE file

    # Type code: which sign(s) a packet is addressed to. "Z" (all types) with
    # address "00" (broadcast) is the standard way to talk to a single sign
    # on a point-to-point RS232 link without needing to know its address.
    #
    # XDF also recognizes two more specific type codes worth knowing about
    # (XDF user guide, section 3.3):
    #   "A" (41H) - XDF/ADF-specific: only XDF or ADF signs respond, useful
    #               if genuine Alpha signs share the same network.
    #   "a" (61H) - the Alpha 4120C-equivalent code specifically for Aurora
    #               63 units (Aurora 64 is "b", Aurora 62 is "t").
    TYPE_ALL = "Z"
    TYPE_XDF_ADF_ONLY = "A"
    TYPE_AURORA_63 = "a"
    BROADCAST_ADDRESS = "00"
  end
end
