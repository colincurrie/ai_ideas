require "test_helper"

module AlphaSign
  class TextFileTest < Minitest::Test
    def test_basic_message_contents
      text = TextFile.new("hi", label: "A", position: Positions::MIDDLE, mode: Modes::HOLD)
      assert_equal "A" + "A" + "\x1B" + "\x20" + "b" + "hi", text.contents
    end

    def test_empty_message_clears_label
      text = TextFile.new("", label: "B")
      assert_equal "AB", text.contents
    end

    def test_priority_uses_label_zero
      text = TextFile.new("urgent", priority: true)
      assert_equal "0", text.label
    end

    def test_to_packet_wraps_in_envelope
      text = TextFile.new("hi")
      packet = text.to_packet
      assert_includes packet.to_s, text.contents
      assert packet.to_s.start_with?(Protocol::WAKEUP + Protocol::SOH)
      assert packet.to_s.end_with?(Protocol::EOT)
    end
  end
end
