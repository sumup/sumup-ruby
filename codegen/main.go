// Command codegen generates the Ruby SDK and its code sample catalogue.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run(args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 || (args[0] != "generate" && args[0] != "samples") {
		return errors.New("usage: codegen <generate|samples> [flags]")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	specPath := flags.String("spec", "../openapi.json", "OpenAPI JSON input (or - for stdin)")
	outDefault := ".."
	if args[0] == "samples" {
		outDefault = "../code-samples.json"
	}
	out := flags.String("out", outDefault, "output directory for generate, file for samples (or - for stdout)")
	check := flags.Bool("check", false, "check generated SDK files without writing")
	versionPath := flags.String("sdk-version-file", "../lib/sumup/version.rb", "Ruby SDK version file for samples")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() > 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	var data []byte
	var err error
	if *specPath == "-" {
		data, err = io.ReadAll(stdin)
	} else {
		data, err = os.ReadFile(*specPath)
	}
	if err != nil {
		return fmt.Errorf("read spec: %w", err)
	}
	spec, err := decode(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("parse spec: %w", err)
	}
	g, err := newGenerator(spec)
	if err != nil {
		return fmt.Errorf("load spec: %w", err)
	}
	if args[0] == "samples" {
		if *check {
			return errors.New("--check is only supported for generate")
		}
		data, err := os.ReadFile(*versionPath)
		if err != nil {
			return fmt.Errorf("read SDK version: %w", err)
		}
		match := regexp.MustCompile(`VERSION = "([^"]+)"`).FindSubmatch(data)
		if match == nil {
			return errors.New("SDK version file has no VERSION assignment")
		}
		data, err = encode(g.samples(string(match[1])))
		if err != nil {
			return fmt.Errorf("encode samples: %w", err)
		}
		if *out == "-" {
			_, err = stdout.Write(data)
		} else {
			err = os.WriteFile(*out, data, 0o644)
		}
		if err != nil {
			return fmt.Errorf("write samples: %w", err)
		}
		return nil
	}
	files, err := g.generate()
	if err != nil {
		return fmt.Errorf("generate SDK: %w", err)
	}
	if *out == "-" {
		data, err := encode(files)
		if err != nil {
			return err
		}
		_, err = stdout.Write(data)
		return err
	}
	return writeFiles(*out, files, *check)
}
func encode(value any) ([]byte, error) {
	var b bytes.Buffer
	encoder := json.NewEncoder(&b)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
func writeFiles(root string, files map[string]string, check bool) error {
	var stale []string
	for _, resource := range []struct{ dir, ext string }{
		{"lib/sumup/resources", ".rb"},
		{"sig/sumup/resources", ".rbs"},
	} {
		dir := filepath.Join(root, filepath.FromSlash(resource.dir))
		err := filepath.WalkDir(dir, func(path string, entry os.DirEntry, err error) error {
			if path == dir && errors.Is(err, os.ErrNotExist) {
				return nil
			}
			if err != nil {
				return err
			}
			if entry.IsDir() || filepath.Ext(path) != resource.ext {
				return nil
			}
			relative, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			if _, ok := files[filepath.ToSlash(relative)]; !ok {
				stale = append(stale, path)
			}
			return nil
		})
		if err != nil {
			return fmt.Errorf("find generated files: %w", err)
		}
	}
	changed := []string{}
	for _, name := range slices.Sorted(maps.Keys(files)) {
		path := filepath.Join(root, filepath.FromSlash(name))
		data, err := os.ReadFile(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("read generated file: %w", err)
		}
		if err != nil || string(data) != files[name] {
			changed = append(changed, name)
		}
	}
	if check {
		if len(changed)+len(stale) > 0 {
			return fmt.Errorf("generated files are out of date: %s", strings.Join(append(changed, stale...), ", "))
		}
		return nil
	}
	for _, name := range slices.Sorted(maps.Keys(files)) {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return fmt.Errorf("create output directory: %w", err)
		}
		if err := os.WriteFile(path, []byte(files[name]), 0o644); err != nil {
			return fmt.Errorf("write generated file: %w", err)
		}
	}
	for _, path := range stale {
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("remove stale file: %w", err)
		}
	}
	return nil
}
