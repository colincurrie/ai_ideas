require "test_helper"

module AlphaSign
  class PacketTest < Minitest::Test
    def test_default_envelope
      packet = Packet.new("XYZ")
      expected = "\x00\x00\x00\x00\x00\x01Z00\x02XYZ\x04"
      assert_equal expected.b, packet.to_s
    end

    def test_custom_type_and_address
      packet = Packet.new("XYZ", type: "1", address: "07")
      expected = "\x00\x00\x00\x00\x00\x01" + "1" + "07" + "\x02XYZ\x04"
      assert_equal expected.b, packet.to_s
    end

    def test_rejects_bad_type_length
      assert_raises(ArgumentError) { Packet.new("XYZ", type: "ZZ") }
    end

    def test_rejects_bad_address_length
      assert_raises(ArgumentError) { Packet.new("XYZ", address: "0") }
    end

    def test_to_hex
      packet = Packet.new("A")
      assert_equal "00 00 00 00 00 01 5A 30 30 02 41 04", packet.to_hex
    end
  end
end
