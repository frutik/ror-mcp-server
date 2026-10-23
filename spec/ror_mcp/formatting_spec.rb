# frozen_string_literal: true

RSpec.describe RorMcp::PythonRepr do
  it "prints dicts, lists and scalars like Python's repr" do
    value = { "a" => [1, 2.5, true, false, nil], "b" => { "c" => "d" } }
    expect(described_class.dump(value)).to eq("{'a': [1, 2.5, True, False, None], 'b': {'c': 'd'}}")
  end

  it "picks double quotes only for text with a single quote and no double quote" do
    expect(described_class.dump("it's")).to eq(%("it's"))
    expect(described_class.dump(%(it's "x"))).to eq(%('it\\'s "x"'))
    expect(described_class.dump("Choices: 'NL' = Netherlands")).to eq(%("Choices: 'NL' = Netherlands"))
  end

  it "escapes control characters and keeps non-ASCII text" do
    expect(described_class.dump("a\nb\\c\u0001é")).to eq("'a\\nb\\\\c\\x01é'")
  end

  it "prints floats like Python" do
    expect(described_class.dump(1e16)).to eq("1e+16")
    expect(described_class.dump(899.0)).to eq("899.0")
  end
end

RSpec.describe RorMcp::Renderers::Json do
  it "renders compact UTF-8 JSON like DRF's JSONRenderer" do
    expect(described_class.render([{ "name" => "Clara Müller", "n" => 1, "ok" => true, "x" => nil }]))
      .to eq('[{"name":"Clara Müller","n":1,"ok":true,"x":null}]')
  end

  it "renders decimals as floats" do
    expect(described_class.render([BigDecimal("499.90"), BigDecimal("899"), 1e16])).to eq("[499.9,899.0,1e+16]")
  end

  it "renders datetimes as ISO 8601 in UTC with Z, microseconds only when present" do
    expect(described_class.render(Time.utc(2024, 11, 26, 12, 23))).to eq('"2024-11-26T12:23:00Z"')
    expect(described_class.render(Time.new(2024, 11, 26, 14, 23, 0, "+02:00"))).to eq('"2024-11-26T12:23:00Z"')
    expect(described_class.render(Time.utc(2024, 1, 1, 0, 0, 0.25r))).to eq('"2024-01-01T00:00:00.250000Z"')
    expect(described_class.render(Date.new(2023, 2, 21))).to eq('"2023-02-21"')
  end

  it "escapes like Python's json module" do
    expect(described_class.render("q\"\\\n\u0001 ")).to eq('"q\\"\\\\\\n\\u0001\\u2028"')
  end
end
