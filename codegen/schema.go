package main

import (
	"encoding/json"
	"fmt"
	"io"
	"reflect"
	"slices"
	"strings"
)

// object retains JSON member order for public method arguments and model fields.
type member struct {
	key   string
	value any
}
type object []member

func (o object) get(key string) any {
	for _, m := range o {
		if m.key == key {
			return m.value
		}
	}
	return nil
}
func (o object) has(key string) bool {
	return slices.ContainsFunc(o, func(m member) bool { return m.key == key })
}
func (o *object) set(key string, value any) {
	for i := range *o {
		if (*o)[i].key == key {
			(*o)[i].value = value
			return
		}
	}
	*o = append(*o, member{key, value})
}
func (o object) without(keys ...string) object {
	var out object
	for _, m := range o {
		if !slices.Contains(keys, m.key) {
			out = append(out, m)
		}
	}
	return out
}
func asObject(v any) object { o, _ := v.(object); return o }
func asArray(v any) []any   { a, _ := v.([]any); return a }
func asString(v any) string { s, _ := v.(string); return s }
func truth(v any) bool      { return v != nil && v != false }
func stringsOf(v any) []string {
	var out []string
	for _, x := range asArray(v) {
		out = append(out, asString(x))
	}
	return out
}
func merge(left, right object) object {
	out := slices.Clone(left)
	for _, m := range right {
		out.set(m.key, m.value)
	}
	return out
}

func equalValue(left, right any) bool {
	switch l := left.(type) {
	case object:
		r, ok := right.(object)
		if !ok || len(l) != len(r) {
			return false
		}
		for _, m := range l {
			if !r.has(m.key) || !equalValue(m.value, r.get(m.key)) {
				return false
			}
		}
		return true
	case []any:
		r, ok := right.([]any)
		return ok && slices.EqualFunc(l, r, equalValue)
	default:
		return reflect.DeepEqual(left, right)
	}
}

func decode(r io.Reader) (object, error) {
	d := json.NewDecoder(r)
	d.UseNumber()
	value, err := decodeValue(d)
	if err != nil {
		return nil, err
	}
	if _, err = d.Token(); err != io.EOF {
		return nil, fmt.Errorf("expected one JSON document")
	}
	o, ok := value.(object)
	if !ok {
		return nil, fmt.Errorf("expected a JSON object")
	}
	return o, nil
}
func decodeValue(d *json.Decoder) (any, error) {
	token, err := d.Token()
	if err != nil {
		return nil, err
	}
	switch token {
	case json.Delim('{'):
		out := object{}
		for d.More() {
			key, err := d.Token()
			if err != nil {
				return nil, err
			}
			v, err := decodeValue(d)
			if err != nil {
				return nil, err
			}
			out.set(key.(string), v)
		}
		_, err = d.Token()
		return out, err
	case json.Delim('['):
		out := []any{}
		for d.More() {
			v, err := decodeValue(d)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		_, err = d.Token()
		return out, err
	default:
		return token, nil
	}
}

func reference(spec object, ref string) (object, error) {
	if !strings.HasPrefix(ref, "#/") {
		return nil, fmt.Errorf("only local references are supported: %s", ref)
	}
	var value any = spec
	for part := range strings.SplitSeq(strings.TrimPrefix(ref, "#/"), "/") {
		key := strings.ReplaceAll(strings.ReplaceAll(part, "~1", "/"), "~0", "~")
		o, ok := value.(object)
		if !ok || !o.has(key) {
			return nil, fmt.Errorf("unresolved reference: %s", ref)
		}
		value = o.get(key)
	}
	o, ok := value.(object)
	if !ok {
		return nil, fmt.Errorf("reference must target an object: %s", ref)
	}
	return o, nil
}
func validateReferences(spec object, value any) error {
	switch v := value.(type) {
	case object:
		if v.has("$ref") {
			if _, err := reference(spec, asString(v.get("$ref"))); err != nil {
				return err
			}
		}
		for _, m := range v {
			if err := validateReferences(spec, m.value); err != nil {
				return err
			}
		}
	case []any:
		for _, item := range v {
			if err := validateReferences(spec, item); err != nil {
				return err
			}
		}
	}
	return nil
}
func (g *generator) resolve(o object) object {
	if !o.has("$ref") {
		return o
	}
	target, _ := reference(g.spec, asString(o.get("$ref"))) // Validated when constructing the generator.
	return merge(target, o.without("$ref"))
}
func (g *generator) merged(schema object, seen ...string) object {
	ref := asString(schema.get("$ref"))
	if ref != "" {
		if slices.Contains(seen, ref) {
			return nil
		}
		seen = append(slices.Clone(seen), ref)
	}
	schema = g.resolve(schema)
	if !schema.has("allOf") {
		return schema
	}
	result := schema.without("allOf")
	for _, raw := range asArray(schema.get("allOf")) {
		part := g.merged(asObject(raw), seen...)
		combined := slices.Clone(part)
		for _, m := range result {
			switch m.key {
			case "properties":
				combined.set(m.key, merge(asObject(part.get(m.key)), asObject(m.value)))
			case "required":
				values := slices.Clone(asArray(part.get(m.key)))
				for _, v := range asArray(m.value) {
					if !slices.Contains(values, v) {
						values = append(values, v)
					}
				}
				combined.set(m.key, values)
			default:
				combined.set(m.key, m.value)
			}
		}
		result = combined
	}
	return result
}
func (g *generator) isObject(schema object) bool { return g.merged(schema).has("properties") }
func (g *generator) properties(schema object) object {
	return asObject(g.merged(schema).get("properties"))
}

type descriptor struct {
	kind  string
	name  string
	items []descriptor
}

func scalar(kind string) descriptor { return descriptor{kind: kind} }
func compound(kind string, item descriptor) descriptor {
	return descriptor{kind: kind, items: []descriptor{item}}
}
func unique(types []descriptor) []descriptor {
	out := []descriptor{}
	for _, t := range types {
		if !slices.ContainsFunc(out, func(x descriptor) bool { return reflect.DeepEqual(x, t) }) {
			out = append(out, t)
		}
	}
	return out
}
func (g *generator) named(name string) descriptor {
	if d, ok := g.descriptors[name]; ok {
		return d
	}
	schema := asObject(g.schemas.get(name))
	if g.isObject(schema) {
		d := descriptor{kind: "model", name: name}
		g.descriptors[name] = d
		return d
	}
	g.descriptors[name] = scalar("any")
	d := g.describe(schema, name)
	g.descriptors[name] = d
	return d
}
func (g *generator) describe(schema object, name string) descriptor {
	if schema.has("$ref") {
		ref := asString(schema.get("$ref"))
		d := g.named(strings.TrimPrefix(ref, "#/components/schemas/"))
		if truth(schema.get("nullable")) {
			return descriptor{kind: "union", items: []descriptor{d, scalar("nil")}}
		}
		return d
	}
	parts := asArray(schema.get("allOf"))
	if len(parts) == 1 && asObject(parts[0]).has("$ref") && len(schema.without("allOf", "title", "description", "example", "examples", "deprecated", "readOnly", "writeOnly", "default", "nullable")) == 0 {
		return g.describe(merge(asObject(parts[0]), schema.without("allOf")), name)
	}
	// Scoped inline definitions belong to their parent model. Named references
	// still use the referenced schema's single canonical type.
	if !strings.Contains(name, "::") {
		for _, m := range g.schemas {
			if m.key != name && !strings.Contains(m.key, "::") && equalValue(m.value, schema) && g.isObject(asObject(m.value)) {
				return g.named(m.key)
			}
		}
	}
	schema = g.merged(schema)
	if values, ok := schema.get("enum").([]any); ok && !slices.ContainsFunc(values, func(v any) bool { _, ok := v.(string); return !ok }) {
		g.enums[name] = stringsOf(values)
	}
	var d descriptor
	variants := asArray(schema.get("oneOf"))
	if variants == nil {
		variants = asArray(schema.get("anyOf"))
	}
	switch {
	case variants != nil:
		var types []descriptor
		for i, v := range variants {
			types = append(types, g.describe(asObject(v), fmt.Sprintf("%sVariant%d", name, i+1)))
		}
		d = descriptor{kind: "union", items: unique(types)}
	case schema.has("properties"):
		if !g.schemas.has(name) {
			g.schemas.set(name, schema)
		}
		d = descriptor{kind: "model", name: name}
		if _, ok := g.descriptors[name]; !ok {
			g.descriptors[name] = d
		}
	default:
		typ := asString(schema.get("type"))
		if values, ok := schema.get("type").([]any); ok {
			for _, v := range values {
				if v != "null" {
					typ = asString(v)
					break
				}
			}
		}
		switch typ {
		case "array":
			d = compound("array", g.describe(asObject(schema.get("items")), name+"Item"))
		case "object":
			value := scalar("any")
			if more, ok := schema.get("additionalProperties").(object); ok {
				value = g.describe(more, name+"Value")
			}
			d = compound("map", value)
		case "string", "integer", "number", "boolean":
			d = scalar(typ)
		case "null":
			d = scalar("nil")
		default:
			d = scalar("any")
		}
	}
	if truth(schema.get("nullable")) || slices.Contains(stringsOf(schema.get("type")), "null") {
		return descriptor{kind: "union", items: []descriptor{d, scalar("nil")}}
	}
	return d
}
func (d descriptor) ruby() string {
	switch d.kind {
	case "model":
		return "[:model, " + quote(typeConstant(d.name)) + "]"
	case "array", "map":
		return "[:" + d.kind + ", " + d.items[0].ruby() + "]"
	case "union":
		items := []string{}
		for _, item := range d.items {
			items = append(items, item.ruby())
		}
		return "[:union, [" + strings.Join(items, ", ") + "]]"
	default:
		return ":" + d.kind
	}
}
func (d descriptor) rbs(input bool) string {
	switch d.kind {
	case "model":
		result := "Types::" + typeConstant(d.name)
		if input {
			result += " | Hash[Symbol | String, untyped]"
		}
		return result
	case "array":
		return "Array[" + d.items[0].rbs(input) + "]"
	case "map":
		key := "String"
		if input {
			key = "Symbol | String"
		}
		return "Hash[" + key + ", " + d.items[0].rbs(input) + "]"
	case "union":
		items := []string{}
		for _, item := range d.items {
			s := item.rbs(input)
			if !slices.Contains(items, s) {
				items = append(items, s)
			}
		}
		return "(" + strings.Join(items, " | ") + ")"
	default:
		return map[string]string{"string": "String", "integer": "Integer", "number": "Numeric", "boolean": "bool", "nil": "nil", "any": "untyped"}[d.kind]
	}
}
