package main

import (
	"cmp"
	"fmt"
)

func (g *generator) collectTagHierarchy() error {
	g.parents = map[string]string{}
	g.childNames = map[string]string{}
	for _, entry := range asArray(g.spec.get("tags")) {
		tag := asObject(entry)
		name := asString(tag.get("name"))
		g.childNames[name] = snake(cmp.Or(asString(tag.get("x-displayName")), name))
	}
	for _, entry := range asArray(g.spec.get("x-tagGroups")) {
		group := asObject(entry)
		parent := asString(group.get("name"))
		for _, child := range stringsOf(group.get("tags")) {
			if parent == child || g.childNames[parent] == "" || g.childNames[child] == "" || g.parents[child] != "" {
				continue
			}
			for ancestor := parent; ancestor != ""; ancestor = g.parents[ancestor] {
				if ancestor == child {
					return fmt.Errorf("tag hierarchy contains a cycle at %s", child)
				}
			}
			g.parents[child] = parent
		}
	}
	return nil
}

func (g *generator) resourcePath(tag string) string {
	if parent := g.parents[tag]; parent != "" {
		return g.resourcePath(parent) + "." + g.childNames[tag]
	}
	return snake(tag)
}

func (g *generator) resourceOperations(tag string) []operation {
	methods := map[string]int{}
	children := map[string]bool{}
	for _, op := range g.operations {
		for parent := g.parents[op.tag]; parent != ""; parent = g.parents[parent] {
			if parent == tag {
				methods[op.name]++
				children[op.tag] = true
			}
		}
		if op.tag == tag {
			methods[op.name]++
		}
	}
	var entries []operation
	for _, op := range g.operations {
		if op.tag == tag {
			entries = append(entries, op)
			continue
		}
		// Keep existing calls through the parent when the method is unambiguous.
		if methods[op.name] == 1 && children[op.tag] {
			entries = append(entries, op)
		}
	}
	return entries
}
