package main

import (
	"cmp"
	"fmt"
	"slices"
	"strings"
)

func orderedParameters(op operation) []object {
	params := slices.Clone(op.parameters)
	slices.SortStableFunc(params, func(a, b object) int {
		return cmp.Compare(boolRank(truth(a.get("required"))), boolRank(truth(b.get("required"))))
	})
	return params
}
func boolRank(value bool) int {
	if value {
		return 0
	}
	return 1
}
func (g *generator) renderResource(tag string, entries []operation) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%smodule SumUp\n  module Resources\n    class %s < Resource\n", header, constant(tag))
	for _, op := range entries {
		b.WriteString(comment(op.description, "      "))
		if op.deprecated {
			b.WriteString("      # @deprecated This API operation is deprecated.\n")
		}
		fmt.Fprintf(&b, "      # @return [%s]\n", op.responseType.rbs(false))
		args := []string{}
		for _, p := range orderedParameters(op) {
			arg := parameterName(p) + ":"
			if !truth(p.get("required")) {
				arg += " UNSET"
			}
			args = append(args, arg)
		}
		if op.body != nil {
			args = append(args, "body: UNSET")
		}
		args = append(args, "options: nil")
		if op.body != nil {
			args = append(args, "**body_fields")
		}
		for _, withResponse := range []bool{false, true} {
			name := op.name
			if withResponse {
				name += "_with_response"
			}
			fmt.Fprintf(&b, "      def %s(%s)\n", name, strings.Join(args, ", "))
			path := pathRE.ReplaceAllStringFunc(op.path, func(match string) string {
				for _, p := range op.parameters {
					if p.get("in") == "path" && p.get("name") == strings.Trim(match, "{}") {
						return "#{path_segment(" + parameterName(p) + ")}"
					}
				}
				return match
			})
			query := []string{}
			headers := []string{}
			for _, p := range op.parameters {
				pair := quote(asString(p.get("name"))) + " => " + parameterName(p)
				switch p.get("in") {
				case "query":
					query = append(query, pair)
				case "header":
					headers = append(headers, pair)
				}
			}
			if len(headers) > 0 {
				fmt.Fprintf(&b, "        options = merge_header_options(options, {%s})\n", strings.Join(headers, ", "))
			}
			if op.body != nil {
				b.WriteString("        payload = request_body(body, body_fields)\n")
				if op.bodyRequired {
					if len(asArray(g.merged(op.body).get("required"))) == 0 {
						b.WriteString("        payload = {} if payload.equal?(UNSET)\n")
					} else {
						b.WriteString("        raise ArgumentError, \"request body is required\" if payload.equal?(UNSET)\n")
					}
				}
			}
			fmt.Fprintf(&b, "        @client.request(method: %s, path: \"%s\",\n", quote(op.verb), path)
			body := ""
			if op.body != nil {
				body = "body: payload, "
			}
			fmt.Fprintf(&b, "          query: {%s}, %soptions: options,\n", strings.Join(query, ", "), body)
			types := []string{}
			for _, r := range op.responses {
				types = append(types, fmt.Sprintf("%d => %s", r.status, r.typ.ruby()))
			}
			fmt.Fprintf(&b, "          response_type: {%s}, with_response: %t)\n", strings.Join(types, ", "), withResponse)
			b.WriteString("      end\n\n")
		}
	}
	return strings.TrimRight(b.String(), "\n") + "\n    end\n  end\nend\n"
}
func (g *generator) renderIndex() string {
	var b strings.Builder
	b.WriteString(header)
	tags := g.tags()
	for _, tag := range tags {
		fmt.Fprintf(&b, "require_relative \"resources/%s\"\n", snake(tag))
	}
	b.WriteString("\nmodule SumUp\n  class Client\n    RESOURCES = {\n")
	entries := []string{}
	for _, tag := range tags {
		entries = append(entries, fmt.Sprintf("      %s: Resources::%s", snake(tag), constant(tag)))
	}
	b.WriteString(strings.Join(entries, ",\n") + "\n    }.freeze\n\n")
	for _, tag := range tags {
		fmt.Fprintf(&b, "    def %s\n      @resources.fetch(:%s)\n    end\n\n", snake(tag), snake(tag))
	}
	return strings.TrimRight(b.String(), "\n") + "\n  end\nend\n"
}
func (g *generator) renderResourceRBS(tag string, entries []operation) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%smodule SumUp\n  class Client\n    def %s: () -> Resources::%s\n  end\n  module Resources\n    class %s < Resource\n", generated, snake(tag), constant(tag), constant(tag))
	for _, op := range entries {
		args := []string{}
		for _, p := range orderedParameters(op) {
			optional := ""
			if !truth(p.get("required")) {
				optional = "?"
			}
			typ := g.describe(asObject(p.get("schema")), constant(op.id)+constant(asString(p.get("name"))))
			args = append(args, optional+parameterName(p)+": "+typ.rbs(false))
		}
		withoutBody := slices.Clone(args)
		if op.body != nil {
			optional := ""
			if !op.bodyRequired {
				optional = "?"
			}
			args = append(args, optional+"body: "+op.bodyType.rbs(true))
		}
		args = append(args, "?options: request_options")
		variants := [][]string{args}
		if op.body != nil && g.isObject(op.body) {
			bodyArgs := append(withoutBody, "?options: request_options")
			name := constant(op.id) + "Request"
			if op.bodyType.kind == "model" {
				name = op.bodyType.name
			}
			required := stringsOf(g.merged(op.body).get("required"))
			for _, p := range g.properties(op.body) {
				optional := "?"
				if slices.Contains(required, p.key) {
					optional = ""
				}
				bodyArgs = append(bodyArgs, optional+fieldName(p.key)+": "+g.describe(asObject(p.value), name+constant(p.key)).rbs(true))
			}
			variants = append(variants, bodyArgs)
		}
		for _, withResponse := range []bool{false, true} {
			name := op.name
			result := op.responseType.rbs(false)
			if withResponse {
				name += "_with_response"
				result = "Response[" + result + "]"
			}
			fmt.Fprintf(&b, "      def %s: ", name)
			rendered := []string{}
			for _, v := range variants {
				rendered = append(rendered, "("+strings.Join(v, ", ")+") -> "+result)
			}
			b.WriteString(strings.Join(rendered, "\n        | ") + "\n")
		}
	}
	return b.String() + "    end\n  end\nend\n"
}

type event struct {
	typ, name, resourceType string
	objectType              descriptor
}

func (g *generator) events() []event {
	events := []event{}
	for _, m := range sortedMembers(asObject(g.spec.get("webhooks"))) {
		op := asObject(g.resolve(asObject(m.value)).get("post"))
		events = append(events, event{typ: m.key, name: constant(strings.TrimSuffix(asString(op.get("operationId")), "Webhook")) + "Event", objectType: g.describe(asObject(op.get("x-object")), "EventResource"), resourceType: asString(op.get("x-object-type"))})
	}
	return events
}
func (g *generator) renderEvents() string {
	var b strings.Builder
	b.WriteString(header + "module SumUp\n")
	events := g.events()
	for _, e := range events {
		fmt.Fprintf(&b, "  class %s < EventNotification\n    TYPE = %s\n    OBJECT_TYPE = %s.freeze\n    RESOURCE_TYPE = %s\n  end\n\n", e.name, quote(e.typ), e.objectType.ruby(), quote(e.resourceType))
	}
	b.WriteString("  module Events\n    TYPES = {\n")
	entries := []string{}
	for _, e := range events {
		entries = append(entries, "      "+quote(e.typ)+" => "+e.name)
	}
	return b.String() + strings.Join(entries, ",\n") + "\n    }.freeze\n  end\nend\n"
}
func (g *generator) renderEventsRBS() string {
	var b strings.Builder
	b.WriteString(generated + "module SumUp\n")
	for _, e := range g.events() {
		fmt.Fprintf(&b, "  class %s < EventNotification\n    TYPE: String\n    def fetch_object: (?options: request_options) -> %s\n  end\n", e.name, e.objectType.rbs(false))
	}
	return b.String() + "end\n"
}
