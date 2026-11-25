package main

import (
	"fmt"
	"maps"
	"slices"
	"strings"
)

// These schemas belong to the reader checkout and settings operations. Shared
// schemas keep their existing constants regardless of which operations use them.
var readerTypeNames = map[string]string{
	"CreateReaderCheckoutRequest":  "Readers::Checkouts::CreateRequest",
	"CreateReaderCheckoutResponse": "Readers::Checkouts::CreateResponse",
	"GetReaderCheckoutResponse":    "Readers::Checkouts::GetResponse",
	"GetReaderSettingsResponse":    "Readers::Settings::GetResponse",
	"UpdateReaderSettingsRequest":  "Readers::Settings::UpdateRequest",
	"UpdateReaderSettingsResponse": "Readers::Settings::UpdateResponse",
}

func typeConstant(key string) string {
	if name := readerTypeNames[key]; name != "" {
		return name
	}
	if strings.Contains(key, "::") {
		return key
	}
	return constant(key)
}

func propertyTypeName(owner, property string) string {
	name := typeConstant(owner)
	if strings.Contains(name, "::") {
		return name + "::" + constant(property)
	}
	return owner + constant(property)
}

type typeDefinition struct {
	path     string
	key      string
	model    bool
	children []*typeDefinition
}

func splitTypePath(path string) (parent, name string) {
	index := strings.LastIndex(path, "::")
	if index == -1 {
		return "", path
	}
	return path[:index], path[index+2:]
}

func (g *generator) renderTypeFiles() (map[string]string, error) {
	var definitions []*typeDefinition
	byPath := map[string]*typeDefinition{}
	add := func(key string, model bool) error {
		path := typeConstant(key)
		if prior := byPath[path]; prior != nil {
			return fmt.Errorf("type constant Types::%s is used by both %s and %s", path, prior.key, key)
		}
		definition := &typeDefinition{path: path, key: key, model: model}
		definitions = append(definitions, definition)
		byPath[path] = definition
		return nil
	}
	for _, schema := range sortedMembers(g.schemas) {
		if g.isObject(asObject(schema.value)) {
			if err := add(schema.key, true); err != nil {
				return nil, err
			}
		}
	}
	for _, key := range slices.Sorted(maps.Keys(g.enums)) {
		if !g.isObject(asObject(g.schemas.get(key))) {
			if err := add(key, false); err != nil {
				return nil, err
			}
		}
	}

	// Reserve the modules containing the scoped models before attaching children.
	for _, definition := range definitions {
		if readerTypeNames[definition.key] == "" {
			continue
		}
		for parent, _ := splitTypePath(definition.path); parent != ""; parent, _ = splitTypePath(parent) {
			prior := byPath[parent]
			if prior != nil {
				if prior.key != "" {
					return nil, fmt.Errorf("type namespace Types::%s conflicts with %s", parent, prior.key)
				}
				continue
			}
			namespace := &typeDefinition{path: parent}
			definitions = append(definitions, namespace)
			byPath[parent] = namespace
		}
	}

	files := map[string]string{}
	var shared, domains []*typeDefinition
	for _, definition := range definitions {
		parent, _ := splitTypePath(definition.path)
		switch {
		case parent != "":
			owner := byPath[parent]
			if owner == nil {
				return nil, fmt.Errorf("missing parent type Types::%s for %s", parent, definition.key)
			}
			owner.children = append(owner.children, definition)
		case definition.key == "":
			domains = append(domains, definition)
		default:
			shared = append(shared, definition)
		}
	}

	var imports strings.Builder
	for _, domain := range domains {
		stem := "types/" + snake(domain.path)
		ruby, err := g.renderTypesFile([]*typeDefinition{domain}, false)
		if err != nil {
			return nil, err
		}
		rbs, err := g.renderTypesFile([]*typeDefinition{domain}, true)
		if err != nil {
			return nil, err
		}
		files["lib/sumup/"+stem+".rb"] = ruby
		files["sig/sumup/"+stem+".rbs"] = rbs
		fmt.Fprintf(&imports, "require_relative %s\n", quote(stem))
	}
	ruby, err := g.renderTypesFile(shared, false)
	if err != nil {
		return nil, err
	}
	rbs, err := g.renderTypesFile(shared, true)
	if err != nil {
		return nil, err
	}
	if imports.Len() > 0 {
		ruby += "\n" + imports.String()
	}
	files["lib/sumup/types.rb"] = ruby
	files["sig/sumup/types.rbs"] = rbs
	return files, nil
}

func (g *generator) renderTypesFile(definitions []*typeDefinition, rbs bool) (string, error) {
	var b strings.Builder
	if rbs {
		b.WriteString(generated)
	} else {
		b.WriteString(header)
	}
	b.WriteString("module SumUp\n  module Types\n")
	if err := g.renderTypeDefinitions(&b, definitions, "    ", rbs); err != nil {
		return "", err
	}
	return strings.TrimRight(b.String(), "\n") + "\n  end\nend\n", nil
}

func (g *generator) renderTypeDefinitions(b *strings.Builder, definitions []*typeDefinition, indent string, rbs bool) error {
	for index, definition := range definitions {
		if index > 0 && !rbs {
			b.WriteByte('\n')
		}
		_, name := splitTypePath(definition.path)
		body := indent + "  "
		switch {
		case definition.model:
			schema := asObject(g.schemas.get(definition.key))
			if !rbs {
				b.WriteString(comment(asString(schema.get("description")), indent))
			}
			fmt.Fprintf(b, "%sclass %s < %s\n", indent, name, modelBase(definition.path))
			if err := g.renderModelFields(b, definition.key, schema, body, rbs); err != nil {
				return err
			}
			if !rbs && len(definition.children) > 0 {
				b.WriteByte('\n')
			}
		case definition.key != "":
			if !rbs {
				fmt.Fprintf(b, "%s# Known values; the API may return additional values.\n", indent)
			}
			fmt.Fprintf(b, "%smodule %s\n", indent, name)
			used := map[string]bool{}
			for _, value := range g.enums[definition.key] {
				key := enumKey(value)
				if used[key] {
					return fmt.Errorf("duplicate enum constant %s::%s", definition.path, key)
				}
				used[key] = true
				if rbs {
					fmt.Fprintf(b, "%s%s: String\n", body, key)
				} else {
					fmt.Fprintf(b, "%s%s = %s\n", body, key, quote(value))
				}
			}
		default:
			fmt.Fprintf(b, "%smodule %s\n", indent, name)
		}
		if err := g.renderTypeDefinitions(b, definition.children, body, rbs); err != nil {
			return err
		}
		fmt.Fprintf(b, "%send\n", indent)
	}
	return nil
}

func modelBase(path string) string {
	if strings.Contains(path, "::") {
		return "::SumUp::Model"
	}
	return "Model"
}

func (g *generator) renderModelFields(b *strings.Builder, key string, schema object, indent string, rbs bool) error {
	used := map[string]bool{}
	required := stringsOf(g.merged(schema).get("required"))
	for _, property := range g.properties(schema) {
		name := fieldName(property.key)
		if used[name] {
			return fmt.Errorf("conflicting model field names in %s", key)
		}
		used[name] = true
		schema := asObject(property.value)
		typ := g.describe(schema, propertyTypeName(key, property.key))
		hasRequired := slices.Contains(required, property.key)
		if rbs {
			fieldType := typ.rbs(false)
			if !hasRequired {
				fieldType = "(" + fieldType + ")?"
			}
			fmt.Fprintf(b, "%sattr_reader %s: %s\n", indent, name, fieldType)
		} else {
			fmt.Fprintf(b, "%s##\n%s# :attr_reader: %s\n", indent, indent, name)
			b.WriteString(comment(asString(schema.get("description")), indent))
			fmt.Fprintf(b, "%sfield :%s, %s, wire: %s, required: %t\n", indent, name, typ.ruby(), quote(property.key), hasRequired)
		}
	}
	return nil
}
