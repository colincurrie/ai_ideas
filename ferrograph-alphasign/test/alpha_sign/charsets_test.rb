require "test_helper"

module AlphaSign
  class CharSetsTest < Minitest::Test
    def test_named_font_lookup
      assert_equal "\x1A3", CharSets.lookup("seven_high")
      assert_equal "\x1A8", CharSets.lookup("large_fancy")
    end

    def test_unknown_font_raises
      assert_raises(ArgumentError) { CharSets.lookup("comic_sans") }
    end
  end
end
