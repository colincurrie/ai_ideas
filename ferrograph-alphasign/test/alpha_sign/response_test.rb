require "test_helper"

module AlphaSign
  class ResponseTest < Minitest::Test
    def framed(contents, checksum: nil)
      body = "#{Protocol::STX}#{contents}#{Protocol::ETX}"
      checksum ||= format("%04X", body.bytes.sum & 0xFFFF)
      "#{Protocol::WAKEUP}#{Protocol::SOH}000#{body}#{checksum}#{Protocol::EOT}"
    end

    def test_parses_a_checksummed_reply
      response = Response.new(framed("E$AAU0100FFFF"))
      assert response.complete?
      # XDF answers with ASCII '0' for both the device identifier and the
      # network address, whatever type/address the request carried.
      assert_equal "0", response.type
      assert_equal "00", response.address
      assert_equal "E$AAU0100FFFF", response.contents
      assert_equal true, response.checksum_ok?
    end

    def test_detects_a_corrupted_reply
      response = Response.new(framed("E$AAU0100FFFF", checksum: "FFFF"))
      assert_equal false, response.checksum_ok?
      assert_equal "FFFF", response.checksum
      refute_equal response.checksum, response.computed_checksum
    end

    # The checksum is the 16-bit sum of every byte from STX to ETX
    # inclusive, as 4 ASCII hex digits.
    def test_computes_the_checksum_over_stx_to_etx_inclusive
      expected = format("%04X", (0x02 + "HI".bytes.sum + 0x03) & 0xFFFF)
      assert_equal expected, Response.new(framed("HI")).computed_checksum
    end

    def test_handles_a_reply_with_no_checksum
      raw = "#{Protocol::WAKEUP}#{Protocol::SOH}000#{Protocol::STX}AB#{Protocol::EOT}"
      response = Response.new(raw)
      assert response.complete?
      assert_equal "AB", response.contents
      assert_nil response.checksum
      # Absent is not the same as wrong - nil, not false.
      assert_nil response.checksum_ok?
    end

    # The likeliest outcome if a read request is malformed: the sign
    # ignores it entirely. That has to be legible, not an exception.
    def test_an_empty_reply_is_reported_not_raised
      response = Response.new("")
      assert response.empty?
      refute response.complete?
      assert_nil response.contents
      assert_equal "", response.to_hex
    end

    def test_a_truncated_reply_keeps_what_arrived
      response = Response.new("#{Protocol::SOH}000#{Protocol::STX}AAHELL")
      refute response.complete?, "no EOT arrived"
      assert_equal "AAHELL", response.contents, "whatever did arrive is still worth seeing"
    end

    def test_garbage_does_not_raise
      response = Response.new("\xFF\xFE nonsense")
      refute response.complete?
      assert_nil response.contents
      assert_includes response.to_hex, "FF"
    end

    # The raw bytes are the evidence for what the sign really said, so they
    # survive whatever the parse makes of them.
    def test_raw_bytes_are_always_available
      raw = framed("IQ0808#{'2' * 8}\r")
      response = Response.new(raw)
      assert_equal raw.bytes.map { |b| format("%02X", b) }.join(" "), response.to_hex
      assert_includes response.to_printable, "IQ0808"
      assert_includes response.to_printable, "<0D>", "control codes are escaped, not emitted"
    end

    def test_to_h_carries_both_the_reading_and_the_evidence
      hash = Response.new(framed("G1HELLO")).to_h
      assert_equal "G1HELLO", hash[:contents_printable]
      assert_equal true, hash[:complete]
      assert_equal true, hash[:checksum_ok]
      assert_includes hash[:raw_hex], "47 31 48"
    end
  end
end
