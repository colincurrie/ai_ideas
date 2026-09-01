require "test_helper"

module AlphaSign
  class DotsFileTest < Minitest::Test
    def test_contents_matches_hand_derived_wire_format
      # I(command) P(label) 02(height=2, hex) 03(width=3, hex)
      # row "123" + _0D(literal CR) + row "000" + _0D
      dots = DotsFile.new(["123", "000"], label: "P")
      assert_equal "IP0203123_0D000_0D", dots.contents
    end

    def test_accepts_named_colors_in_rows
      dots = DotsFile.new([%w[off red green yellow]], label: "P")
      assert_equal "IP01040123_0D", dots.contents
    end

    def test_height_and_width
      dots = DotsFile.new(["12301", "00220", "11311"])
      assert_equal 3, dots.height
      assert_equal 5, dots.width
    end

    def test_rejects_ragged_rows
      assert_raises(ArgumentError) { DotsFile.new(["123", "00"]) }
    end

    def test_rejects_empty_rows
      assert_raises(ArgumentError) { DotsFile.new([]) }
    end

    def test_rejects_oversized_dimensions
      assert_raises(ArgumentError) { DotsFile.new(["0"] * 33) } # > MAX_HEIGHT
      assert_raises(ArgumentError) { DotsFile.new(["0" * 256]) } # > MAX_WIDTH
    end

    def test_lit_fraction
      dots = DotsFile.new(["1200"]) # 2 of 4 pixels lit
      assert_in_delta 0.5, dots.lit_fraction
    end

    def test_lit_chip_fraction_counts_yellow_as_two_chips
      # all-yellow row: max possible load -> chip fraction should be 1.0
      assert_in_delta 1.0, DotsFile.new(["333"]).lit_chip_fraction
      # all-off: zero load
      assert_in_delta 0.0, DotsFile.new(["000"]).lit_chip_fraction
      # one red pixel out of 2 possible chips (1 pixel * 2 chips max) -> 0.5
      assert_in_delta 0.5, DotsFile.new(["1"]).lit_chip_fraction
    end

    def test_to_packet_wraps_contents
      dots = DotsFile.new(["1"], label: "P")
      packet = dots.to_packet
      assert_includes packet.to_s, dots.contents
    end
  end
end
