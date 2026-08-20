package engine

import (
	"testing"
)

// The fixtures below are the spec's own, taken verbatim from toon_rust's
// `tests/fixtures/spec/encode/`. They are the only normative data available:
// beads_viewer ships no TOON goldens of its own, because it shells out to the
// Rust binary and its tests skip when that binary is absent.

func TestTOONSpecFixtures(t *testing.T) {
	cases := []struct {
		name string
		json string
		want string
	}{
		{
			name: "nested objects",
			json: `{"a":{"b":{"c":"deep"}}}`,
			want: "a:\n  b:\n    c: deep",
		},
		{
			name: "key needing quotes",
			json: `{"order:id":7}`,
			want: `"order:id": 7`,
		},
		{
			name: "escaped quotes in a value",
			json: `{"text":"say \"hello\""}`,
			want: `text: "say \"hello\""`,
		},
		{
			name: "primitives that look like other types",
			json: `{"items":["x","true","42","-3.14"]}`,
			want: `items[4]: x,"true","42","-3.14"`,
		},
		{
			name: "empty array",
			json: `{"items":[]}`,
			want: "items[0]:",
		},
		{
			name: "tabular array",
			json: `{"items":[{"sku":"A1","qty":2,"price":9.99},` +
				`{"sku":"B2","qty":1,"price":14.5}]}`,
			want: "items[2]{sku,qty,price}:\n  A1,2,9.99\n  B2,1,14.5",
		},
		{
			name: "tabular cells needing quotes",
			json: `{"items":[{"sku":"A,1","desc":"cool","qty":2},` +
				`{"sku":"B2","desc":"wip: test","qty":1}]}`,
			want: "items[2]{sku,desc,qty}:\n  \"A,1\",cool,2\n  B2,\"wip: test\",1",
		},
		{
			name: "tabular headers needing quotes",
			json: `{"items":[{"order:id":1,"full name":"Ada"},` +
				`{"order:id":2,"full name":"Bob"}]}`,
			want: "items[2]{\"order:id\",\"full name\"}:\n  1,Ada\n  2,Bob",
		},
		{
			name: "ragged objects fall back to the list form",
			json: `{"items":[{"id":1,"name":"First"},` +
				`{"id":2,"name":"Second","extra":true}]}`,
			want: "items[2]:\n  - id: 1\n    name: First\n  - id: 2\n    name: Second\n    extra: true",
		},
		{
			name: "empty object in a list",
			json: `{"items":["first","second",{}]}`,
			want: "items[3]:\n  - first\n  - second\n  -",
		},
		{
			name: "root array of primitives",
			json: `["x","y","true",true,10]`,
			want: `[5]: x,y,"true",true,10`,
		},
		{
			name: "mixed object",
			json: `{"user":{"id":123,"name":"Ada","tags":["reading","gaming"],` +
				`"active":true,"prefs":[]}}`,
			want: "user:\n  id: 123\n  name: Ada\n  tags[2]: reading,gaming\n" +
				"  active: true\n  prefs[0]:",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := EncodeTOON([]byte(c.json))
			if err != nil {
				t.Fatalf("EncodeTOON: %v", err)
			}
			if got != c.want {
				t.Errorf("\n got: %q\nwant: %q", got, c.want)
			}
		})
	}
}

func TestTOONQuotingRules(t *testing.T) {
	cases := map[string]bool{
		"plain":       false,
		"":            true,
		" leading":    true,
		"trailing ":   true,
		"true":        true,
		"false":       true,
		"null":        true,
		"42":          true,
		"-3.14":       true,
		"1e5":         true,
		"05":          true,
		"-dash":       true,
		"#hash":       true,
		"has:colon":   true,
		"has,comma":   true,
		"has[bracket": true,
		"has{brace":   true,
		`has"quote`:   true,
		`has\slash`:   true,
		// Non-ASCII is deliberately not a trigger — this is where a naive
		// implementation over-quotes.
		"café":  false,
		"你好":    false,
		"🚀":     false,
		"a b c": false,
	}

	for value, shouldQuote := range cases {
		if got := toonNeedsQuoting(value); got != shouldQuote {
			t.Errorf("toonNeedsQuoting(%q) = %v, want %v", value, got, shouldQuote)
		}
	}
}

func TestTOONNumberCanonicalisation(t *testing.T) {
	cases := map[string]string{
		`{"n":1.0}`:   "n: 1",
		`{"n":-0.0}`:  "n: 0",
		`{"n":0}`:     "n: 0",
		`{"n":1e6}`:   "n: 1000000",
		`{"n":1e-6}`:  "n: 0.000001",
		`{"n":1e21}`:  "n: 1e+21",
		`{"n":9.99}`:  "n: 9.99",
		`{"n":14.50}`: "n: 14.5",
		`{"n":-3.14}`: "n: -3.14",
	}
	for input, want := range cases {
		got, err := EncodeTOON([]byte(input))
		if err != nil {
			t.Fatalf("EncodeTOON(%s): %v", input, err)
		}
		if got != want {
			t.Errorf("EncodeTOON(%s) = %q, want %q", input, got, want)
		}
	}
}

func TestTOONControlCharactersEscape(t *testing.T) {
	got, err := EncodeTOON([]byte(`{"t":"a\tb\nc\u0001d"}`))
	if err != nil {
		t.Fatal(err)
	}
	want := `t: "a\tb\nc\u0001d"`
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestTOONPreservesKeyOrder(t *testing.T) {
	// Go randomises map iteration, so encoding through a map would produce a
	// different rendering on every run. Order has to survive the parse.
	input := `{"zulu":1,"alpha":2,"mike":3}`
	want := "zulu: 1\nalpha: 2\nmike: 3"

	for i := 0; i < 20; i++ {
		got, err := EncodeTOON([]byte(input))
		if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("key order is unstable: got %q", got)
		}
	}
}

func TestTOONEmptyRootForms(t *testing.T) {
	cases := map[string]string{
		`{}`:   "",
		`[]`:   "[0]:",
		`null`: "null",
		`true`: "true",
		`"x"`:  "x",
	}
	for input, want := range cases {
		got, err := EncodeTOON([]byte(input))
		if err != nil {
			t.Fatalf("EncodeTOON(%s): %v", input, err)
		}
		if got != want {
			t.Errorf("EncodeTOON(%s) = %q, want %q", input, got, want)
		}
	}
}

func TestTOONMethodRoundTrip(t *testing.T) {
	s := openFixture(t)
	var result struct {
		TOON string `json:"toon"`
	}
	result = call[struct {
		TOON string `json:"toon"`
	}](t, s, "toon", map[string]any{
		"value": map[string]any{"a": 1, "b": "two"},
	})

	if result.TOON == "" {
		t.Fatal("the method returned nothing")
	}
	// TOON never starts with a brace; that is how bv's own tests tell the two
	// formats apart.
	if result.TOON[0] == '{' {
		t.Errorf("output looks like JSON: %q", result.TOON)
	}
}

func TestTOONMethodRejectsAnEmptyRequest(t *testing.T) {
	s := openFixture(t)
	for _, req := range [][]byte{nil, []byte(`{}`)} {
		if _, err := s.Call("toon", req); err == nil {
			t.Errorf("expected an error for %q", req)
		}
	}
}
