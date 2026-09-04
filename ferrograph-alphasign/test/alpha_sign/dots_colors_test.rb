require "test_helper"

module AlphaSign
  class DotsColorsTest < Minitest::Test
    def test_named_lookup
      assert_equal "0", DotsColors.lookup("off")
      assert_equal "1", DotsColors.lookup("red")
      assert_equal "2", DotsColors.lookup("green")
      assert_equal "3", DotsColors.lookup("yellow")
    end

    def test_bare_code_passthrough
      assert_equal "0", DotsColors.lookup("0")
      assert_equal "3", DotsColors.lookup("3")
    end

    def test_unknown_raises
      assert_raises(ArgumentError) { DotsColors.lookup("purple") }
      assert_raises(ArgumentError) { DotsColors.lookup("9") }
    end
  end
end
