require "test_helper"

module AlphaSign
  class StringFileTest < Minitest::Test
    def test_contents_use_the_write_string_command
      assert_equal "G1HELLO", StringFile.new("HELLO", label: "1").contents
    end

    def test_default_label_is_one
      assert_equal "1", StringFile.new("HI").label
    end

    def test_empty_text_clears_the_string
      assert_equal "G2", StringFile.new("", label: "2").contents
    end

    def test_packet_wraps_the_contents
      packet = StringFile.new("HI", label: "1").to_packet(type: "a", address: "01")
      assert_equal Packet.new("G1HI", type: "a", address: "01").to_hex, packet.to_hex
    end
  end
end
