# coding: ascii-8bit

# stdlib
require "pathname"

# test helpers
require_relative "test_helper"

# this library
require "ruby-openid2"
require "openid/cryptutil"

class CryptUtilTestCase < Minitest::Test
  BIG = 2**256

  def test_rand
    # If this is not true, the rest of our test won't work
    assert_kind_of(Integer, BIG)

    # It's possible that these will be small enough for fixnums, but
    # extraorindarily unlikely.
    a = OpenID::CryptUtil.rand(BIG)
    b = OpenID::CryptUtil.rand(BIG)

    assert_kind_of(Integer, a)
    assert_kind_of(Integer, b)
    refute_equal(a, b)
  end

  def test_rand_doesnt_depend_on_srand
    Kernel.srand(1)
    a = OpenID::CryptUtil.rand(BIG)
    Kernel.srand(1)
    b = OpenID::CryptUtil.rand(BIG)

    refute_equal(a, b)
  end

  def test_random_binary_convert
    501.times do
      n = (0..10).inject(0) { |sum, _element| sum + OpenID::CryptUtil.rand(BIG) }
      s = OpenID::CryptUtil.num_to_binary(n)

      assert_kind_of(String, s)
      n_converted_back = OpenID::CryptUtil.binary_to_num(s)

      assert_equal(n, n_converted_back)
    end
  end

  def test_enumerated_binary_convert
    {
      "\x00" => 0,
      "\x01" => 1,
      "\x7F" => 127,
      "\x00\xFF" => 255,
      "\x00\x80" => 128,
      "\x00\x81" => 129,
      "\x00\x80\x00" => 32_768,
      "OpenID is cool" => 1_611_215_304_203_901_150_134_421_257_416_556,
    }.each do |str, num|
      num_prime = OpenID::CryptUtil.binary_to_num(str)
      str_prime = OpenID::CryptUtil.num_to_binary(num)

      assert_equal(num, num_prime)
      assert_equal(str, str_prime)
    end
  end

  def with_n2b64
    test_dir = Pathname.new(__FILE__).dirname
    filename = test_dir.join("data", "n2b64")
    File.open(filename) do |file|
      file.each_line do |line|
        base64, base10 = line.chomp.split
        yield base64, base10.to_i
      end
    end
  end

  def test_base64_to_num
    with_n2b64 do |base64, num|
      assert_equal(num, OpenID::CryptUtil.base64_to_num(base64))
    end
  end

  def test_base64_to_num_invalid
    assert_raises(ArgumentError) do
      OpenID::CryptUtil.base64_to_num('!@#$')
    end
  end

  def test_num_to_base64
    with_n2b64 do |base64, num|
      assert_equal(base64, OpenID::CryptUtil.num_to_base64(num))
    end
  end

  def test_randomstring
    s1 = OpenID::CryptUtil.random_string(42)

    assert_equal(42, s1.length)
    s2 = OpenID::CryptUtil.random_string(42)

    assert_equal(42, s2.length)
    refute_equal(s1, s2)
  end

  def test_randomstring_population
    s1 = OpenID::CryptUtil.random_string(42, "XO")

    assert_match(/[XO]{42}/, s1)
  end

  def test_sha1
    assert_equal(
      "\x11\xf6\xad\x8e\xc5*)\x84\xab\xaa\xfd|;Qe\x03x\\ r",
      OpenID::CryptUtil.sha1("x"),
    )
  end

  def test_hmac_sha1
    assert_equal(
      "\x8bo\xf7O\xa7\x18*\x90\xac ah\x16\xf7\xb8\x81JB\x9f|",
      OpenID::CryptUtil.hmac_sha1("x", "x"),
    )
  end

  def test_sha256
    assert_equal(
      "-q\x16B\xb7&\xb0D\x01b|\xa9\xfb\xac2\xf5\xc8S\x0f\xb1\x90<\xc4\xdb\x02%\x87\x17\x92\x1aH\x81",
      OpenID::CryptUtil.sha256("x"),
    )
  end

  def test_hmac_sha256
    assert_equal(
      "\x94{\xd2w\xb2\xd3\\\xfc\x07\xfb\xc7\xe3b\xf2iuXz1\xf8:}\xffx\x8f\xda\xc1\xfaC\xc4\xb2\x87",
      OpenID::CryptUtil.hmac_sha256("x", "x"),
    )
  end
end
