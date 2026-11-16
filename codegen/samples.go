package main

import (
	"cmp"
	"slices"
	"strings"
)

type catalog struct {
	SchemaVersion  int      `json:"schemaVersion"`
	Language       string   `json:"language"`
	SDK            sdk      `json:"sdk"`
	OpenAPIVersion string   `json:"openAPIVersion"`
	Samples        []sample `json:"samples"`
}
type sdk struct {
	Module  string `json:"module"`
	Version string `json:"version"`
}
type sample struct {
	ID          string `json:"id"`
	OperationID string `json:"operationId"`
	HTTPMethod  string `json:"httpMethod"`
	Path        string `json:"path"`
	Sample      string `json:"sample"`
	Example     string `json:"example,omitempty"`
}

func (g *generator) sampleValue(schema object, depth int) any {
	if depth > 8 {
		return "example"
	}
	schema = g.merged(schema)
	if schema.has("example") {
		return schema.get("example")
	}
	if schema.has("default") {
		return schema.get("default")
	}
	if values := asArray(schema.get("enum")); len(values) > 0 {
		return values[0]
	}
	variants := asArray(schema.get("oneOf"))
	if variants == nil {
		variants = asArray(schema.get("anyOf"))
	}
	if len(variants) > 0 {
		return g.sampleValue(asObject(variants[0]), depth+1)
	}
	if schema.has("properties") {
		out := object{}
		properties := asObject(schema.get("properties"))
		for _, key := range stringsOf(schema.get("required")) {
			out.set(key, g.sampleValue(asObject(properties.get(key)), depth+1))
		}
		return out
	}
	switch schema.get("type") {
	case "integer", "number":
		if schema.has("minimum") {
			return schema.get("minimum")
		}
		return 1
	case "boolean":
		return true
	case "array":
		return []any{g.sampleValue(asObject(schema.get("items")), depth+1)}
	case "object":
		return object{}
	default:
		return "example"
	}
}
func (g *generator) samples(version string) catalog {
	out := catalog{SchemaVersion: 1, Language: "ruby", SDK: sdk{Module: "sumup", Version: version}, OpenAPIVersion: asString(asObject(g.spec.get("info")).get("version")), Samples: []sample{}}
	for _, op := range g.operations {
		examples := op.examples
		if len(examples) == 0 {
			var value any
			if op.body != nil {
				value = g.sampleValue(op.body, 0)
			}
			examples = object{{"", object{{"value", value}}}}
		}
		for _, example := range examples {
			raw := g.resolve(asObject(example.value))
			args := []string{}
			for _, p := range op.parameters {
				if truth(p.get("required")) {
					args = append(args, parameterName(p)+": "+literal(g.sampleValue(asObject(p.get("schema")), 0)))
				}
			}
			if op.body != nil {
				args = append(args, "body: "+literal(raw.get("value")))
			}
			code := "require \"sumup\"\n\nclient = SumUp::Client.new(api_key: ENV.fetch(\"SUMUP_API_KEY\"))\nresult = client." + snake(op.tag) + "." + op.name + "(" + strings.Join(args, ", ") + ")\n"
			id := op.id
			if example.key != "" {
				id += "." + example.key
			}
			out.Samples = append(out.Samples, sample{ID: id, OperationID: op.id, HTTPMethod: op.verb, Path: op.path, Sample: code, Example: example.key})
		}
	}
	slices.SortFunc(out.Samples, func(a, b sample) int { return cmp.Compare(a.ID, b.ID) })
	return out
}
