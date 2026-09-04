require "test_helper"

module AlphaSign
  class ColorsTest < Minitest::Test
    def test_named_color_lookup
      assert_equal "\x1C1", Colors.lookup("red")
      assert_equal "\x1C1", Colors.lookup("RED")
      assert_equal "\x1C2", Colors.lookup("green")
      assert_equal "\x1C3", Colors.lookup("amber")
      assert_equal "\x1C8", Colors.lookup("yellow")
    end

    def test_xdf_specific_colors
      assert_equal "\x1CD", Colors.lookup("stripe_red_green_red")
      assert_equal "\x1Cl", Colors.lookup("small_stripe_yellow_green")
    end

    def test_unknown_named_color_raises
      assert_raises(ArgumentError) { Colors.lookup("plaid") }
    end

    def test_hex_color_is_not_supported
      assert_raises(ArgumentError) { Colors.lookup("#FF00AA") }
    end
  end
end
