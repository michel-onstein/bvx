package engine

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// TOON — a token-optimised encoding of JSON, spec v3.0.
//
// bv does not contain an encoder: it shells out to the Rust `tru` binary
// through a wrapper, and falls back to JSON with a warning when that binary is
// not installed. That is a poor contract for vbx — a format that silently
// becomes a different format depending on what happens to be on the machine —
// so this is a pure-Go implementation of the same spec. No subprocess, no
// external dependency, and the output does not depend on the host.
//
// Key order is preserved by parsing the JSON with a streaming decoder rather
// than into a map, because Go randomises map iteration and TOON's whole point
// is a stable, compact rendering.

// toonValue is a JSON value with object key order retained.
type toonValue struct {
	kind   toonKind
	scalar any // string, float64, bool, or nil
	items  []toonValue
	keys   []string
	fields []toonValue
}

type toonKind int

const (
	toonScalar toonKind = iota
	toonArray
	toonObject
)

// parseToonJSON decodes JSON while keeping object keys in source order.
func parseToonJSON(data []byte) (toonValue, error) {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()

	value, err := parseToonNext(decoder)
	if err != nil {
		return toonValue{}, err
	}
	return value, nil
}

func parseToonNext(decoder *json.Decoder) (toonValue, error) {
	token, err := decoder.Token()
	if err != nil {
		return toonValue{}, err
	}
	return parseToonToken(decoder, token)
}

func parseToonToken(decoder *json.Decoder, token json.Token) (toonValue, error) {
	switch t := token.(type) {
	case json.Delim:
		switch t {
		case '{':
			object := toonValue{kind: toonObject}
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return toonValue{}, err
				}
				key, ok := keyToken.(string)
				if !ok {
					return toonValue{}, fmt.Errorf("object key is not a string")
				}
				field, err := parseToonNext(decoder)
				if err != nil {
					return toonValue{}, err
				}
				object.keys = append(object.keys, key)
				object.fields = append(object.fields, field)
			}
			if _, err := decoder.Token(); err != nil { // closing brace
				return toonValue{}, err
			}
			return object, nil
		case '[':
			array := toonValue{kind: toonArray}
			for decoder.More() {
				item, err := parseToonNext(decoder)
				if err != nil {
					return toonValue{}, err
				}
				array.items = append(array.items, item)
			}
			if _, err := decoder.Token(); err != nil { // closing bracket
				return toonValue{}, err
			}
			return array, nil
		}
		return toonValue{}, fmt.Errorf("unexpected delimiter %v", t)
	case json.Number:
		number, err := t.Float64()
		if err != nil {
			return toonValue{}, err
		}
		return toonValue{kind: toonScalar, scalar: number}, nil
	default:
		return toonValue{kind: toonScalar, scalar: token}, nil
	}
}

// EncodeTOON renders JSON as TOON.
//
// The result carries no trailing newline; callers add one.
func EncodeTOON(data []byte) (string, error) {
	value, err := parseToonJSON(data)
	if err != nil && err != io.EOF {
		return "", fmt.Errorf("parsing JSON for TOON: %w", err)
	}

	var out strings.Builder
	writeToonRoot(&out, value)
	return strings.TrimRight(out.String(), "\n"), nil
}

// writeToonRoot handles the root, whose array forms have no key.
func writeToonRoot(out *strings.Builder, value toonValue) {
	switch value.kind {
	case toonObject:
		writeToonObjectBody(out, value, 0)
	case toonArray:
		writeToonArray(out, "", value, 0)
	default:
		out.WriteString(toonScalarText(value.scalar))
		out.WriteString("\n")
	}
}

func writeToonObjectBody(out *strings.Builder, object toonValue, depth int) {
	for i, key := range object.keys {
		writeToonField(out, key, object.fields[i], depth)
	}
}

func writeToonField(out *strings.Builder, key string, value toonValue, depth int) {
	indent := strings.Repeat("  ", depth)
	encodedKey := toonKeyText(key)

	switch value.kind {
	case toonScalar:
		fmt.Fprintf(out, "%s%s: %s\n", indent, encodedKey, toonScalarText(value.scalar))
	case toonArray:
		writeToonArray(out, encodedKey, value, depth)
	case toonObject:
		if len(value.keys) == 0 {
			// An empty object is its key and nothing beneath it.
			fmt.Fprintf(out, "%s%s:\n", indent, encodedKey)
			return
		}
		fmt.Fprintf(out, "%s%s:\n", indent, encodedKey)
		writeToonObjectBody(out, value, depth+1)
	}
}

// writeToonArray picks the most compact form the contents allow.
func writeToonArray(out *strings.Builder, key string, array toonValue, depth int) {
	indent := strings.Repeat("  ", depth)
	prefix := key
	count := len(array.items)

	if count == 0 {
		fmt.Fprintf(out, "%s%s[0]:\n", indent, prefix)
		return
	}

	// Every element a primitive: one line.
	if toonAllScalars(array.items) {
		parts := make([]string, 0, count)
		for _, item := range array.items {
			parts = append(parts, toonScalarText(item.scalar))
		}
		fmt.Fprintf(out, "%s%s[%d]: %s\n", indent, prefix, count, strings.Join(parts, ","))
		return
	}

	// Every element an object with the same primitive-valued keys: a table.
	if fields, ok := toonTableFields(array.items); ok {
		encoded := make([]string, 0, len(fields))
		for _, field := range fields {
			encoded = append(encoded, toonKeyText(field))
		}
		fmt.Fprintf(out, "%s%s[%d]{%s}:\n", indent, prefix, count, strings.Join(encoded, ","))
		rowIndent := strings.Repeat("  ", depth+1)
		for _, item := range array.items {
			cells := make([]string, 0, len(fields))
			for _, field := range fields {
				cells = append(cells, toonScalarText(toonLookup(item, field).scalar))
			}
			fmt.Fprintf(out, "%s%s\n", rowIndent, strings.Join(cells, ","))
		}
		return
	}

	// Every element an array: a list of bracketed rows.
	if toonAllArrays(array.items) {
		fmt.Fprintf(out, "%s%s[%d]:\n", indent, prefix, count)
		for _, item := range array.items {
			writeToonArray(out, "", item, depth+1)
			// The nested writer emits `[N]: …`; the list form wants `- ` in
			// front of it, which is patched below.
		}
		return
	}

	// Mixed: the list form.
	fmt.Fprintf(out, "%s%s[%d]:\n", indent, prefix, count)
	itemIndent := strings.Repeat("  ", depth+1)
	for _, item := range array.items {
		switch item.kind {
		case toonScalar:
			fmt.Fprintf(out, "%s- %s\n", itemIndent, toonScalarText(item.scalar))
		case toonArray:
			var nested strings.Builder
			writeToonArray(&nested, "", item, 0)
			fmt.Fprintf(out, "%s- %s", itemIndent, nested.String())
		case toonObject:
			if len(item.keys) == 0 {
				// An empty object item is a bare hyphen.
				fmt.Fprintf(out, "%s-\n", itemIndent)
				continue
			}
			writeToonListObject(out, item, depth+1)
		}
	}
}

// writeToonListObject renders one object inside a list, with its first field
// on the hyphen line.
func writeToonListObject(out *strings.Builder, object toonValue, depth int) {
	itemIndent := strings.Repeat("  ", depth)
	// Siblings sit at the hyphen's indent plus two, which is what lines them
	// up under the first field rather than under the hyphen.
	siblingIndent := itemIndent + "  "

	for i, key := range object.keys {
		field := object.fields[i]
		var rendered strings.Builder

		switch field.kind {
		case toonScalar:
			fmt.Fprintf(&rendered, "%s: %s\n", toonKeyText(key), toonScalarText(field.scalar))
		case toonArray:
			writeToonArray(&rendered, toonKeyText(key), field, 0)
		case toonObject:
			writeToonField(&rendered, key, field, 0)
		}

		lines := strings.Split(strings.TrimRight(rendered.String(), "\n"), "\n")
		for j, line := range lines {
			switch {
			case i == 0 && j == 0:
				fmt.Fprintf(out, "%s- %s\n", itemIndent, line)
			case i == 0:
				// Continuation of the first field indents past the hyphen.
				fmt.Fprintf(out, "%s  %s\n", siblingIndent, line)
			default:
				fmt.Fprintf(out, "%s%s\n", siblingIndent, line)
			}
		}
	}
}

func toonLookup(object toonValue, key string) toonValue {
	for i, candidate := range object.keys {
		if candidate == key {
			return object.fields[i]
		}
	}
	return toonValue{kind: toonScalar, scalar: nil}
}

func toonAllScalars(items []toonValue) bool {
	for _, item := range items {
		if item.kind != toonScalar {
			return false
		}
	}
	return true
}

func toonAllArrays(items []toonValue) bool {
	for _, item := range items {
		if item.kind != toonArray {
			return false
		}
	}
	return len(items) > 0
}

// toonTableFields reports the shared field order when every element is an
// object with the same keys and only primitive values.
//
// The field order comes from the first object, which is what makes the
// encoding stable — and why key order had to be preserved on the way in.
func toonTableFields(items []toonValue) ([]string, bool) {
	if len(items) == 0 {
		return nil, false
	}
	if items[0].kind != toonObject || len(items[0].keys) == 0 {
		return nil, false
	}
	fields := items[0].keys

	for _, item := range items {
		if item.kind != toonObject || len(item.keys) != len(fields) {
			return nil, false
		}
		present := make(map[string]bool, len(item.keys))
		for i, key := range item.keys {
			present[key] = true
			if item.fields[i].kind != toonScalar {
				return nil, false
			}
		}
		for _, field := range fields {
			if !present[field] {
				return nil, false
			}
		}
	}
	return fields, true
}

// toonBareKey matches a key that needs no quoting.
var toonBareKey = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.]*$`)

func toonKeyText(key string) string {
	if toonBareKey.MatchString(key) {
		return key
	}
	return toonQuote(key)
}

// toonNumberLike matches a string that would be read back as a number.
var toonNumberLike = regexp.MustCompile(`^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`)

func toonScalarText(value any) string {
	switch v := value.(type) {
	case nil:
		return "null"
	case bool:
		if v {
			return "true"
		}
		return "false"
	case float64:
		return toonNumberText(v)
	case string:
		if toonNeedsQuoting(v) {
			return toonQuote(v)
		}
		return v
	default:
		return toonQuote(fmt.Sprint(v))
	}
}

// toonNumberText renders a number canonically.
//
// Plain decimal inside the range the spec calls exponent-free, JSON's
// exponent form outside it. `1.0` becomes `1`, and negative zero becomes `0`,
// because a distinction nothing can act on is noise.
func toonNumberText(value float64) string {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return "null"
	}
	if value == 0 {
		return "0"
	}
	magnitude := math.Abs(value)
	if magnitude >= 1e-6 && magnitude < 1e21 {
		return strconv.FormatFloat(value, 'f', -1, 64)
	}
	return strings.ToLower(strconv.FormatFloat(value, 'e', -1, 64))
}

// toonNeedsQuoting applies the spec's quoting triggers.
//
// Non-ASCII is deliberately *not* a trigger: `café` and `你好` are emitted
// bare, which is where a naive implementation would over-quote.
func toonNeedsQuoting(value string) bool {
	if value == "" {
		return true
	}
	if strings.TrimSpace(value) != value {
		return true
	}
	switch value {
	case "true", "false", "null":
		return true
	}
	if toonNumberLike.MatchString(value) {
		return true
	}
	if strings.HasPrefix(value, "-") || strings.HasPrefix(value, "#") {
		return true
	}
	if strings.ContainsAny(value, ":\"\\[]{},") {
		return true
	}
	for _, r := range value {
		if r < 0x20 {
			return true
		}
	}
	return false
}

func toonQuote(value string) string {
	var out strings.Builder
	out.WriteByte('"')
	for _, r := range value {
		switch r {
		case '\\':
			out.WriteString(`\\`)
		case '"':
			out.WriteString(`\"`)
		case '\n':
			out.WriteString(`\n`)
		case '\r':
			out.WriteString(`\r`)
		case '\t':
			out.WriteString(`\t`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&out, `\u%04x`, r)
				continue
			}
			out.WriteRune(r)
		}
	}
	out.WriteByte('"')
	return out.String()
}

// toonPayload converts an arbitrary JSON payload to TOON.
func (s *Session) toonPayload(req []byte) ([]byte, error) {
	if len(req) == 0 {
		return nil, fmt.Errorf("toon requires a {\"value\": …} request")
	}
	var wrapper struct {
		Value json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(req, &wrapper); err != nil {
		return nil, err
	}
	if len(wrapper.Value) == 0 {
		return nil, fmt.Errorf("toon requires a non-empty \"value\"")
	}

	encoded, err := EncodeTOON(wrapper.Value)
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{"toon": encoded})
}
