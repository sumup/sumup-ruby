package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

const widgetPath = `{"parameters":[{"name":"id","in":"path","required":true,"schema":{"type":"string"}}],"get":{"operationId":"GetWidget","description":"Read the merchant’s widget","tags":["Widgets"],"x-codegen":{"method_name":"get"},"responses":{"200":{"content":{"application/json":{"schema":{"type":"object"}}}}}}}`

func fixture(t *testing.T, schemas, path string) *generator {
	t.Helper()
	if schemas == "" {
		schemas = "{}"
	}
	if path == "" {
		path = widgetPath
	}
	data := `{"openapi":"3.1.0","info":{"version":"1.0.0"},"components":{"schemas":` + schemas + `},"paths":{"/widgets/{id}":` + path + `}}`
	spec, err := decode(strings.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	g, err := newGenerator(spec)
	if err != nil {
		t.Fatal(err)
	}
	return g
}
func generatedFiles(t *testing.T, g *generator) map[string]string {
	t.Helper()
	files, err := g.generate()
	if err != nil {
		t.Fatal(err)
	}
	return files
}
func contains(t *testing.T, source, want string) {
	t.Helper()
	if !strings.Contains(source, want) {
		t.Fatalf("expected generated source to contain %q", want)
	}
}

func TestNestedResources(t *testing.T) {
	t.Parallel()
	spec, err := decode(strings.NewReader(`{
	  "openapi":"3.1.0","info":{"version":"1.0.0"},
	  "tags":[{"name":"Readers"},{"name":"ReaderCheckouts","x-displayName":"Checkouts"}],
	  "x-tagGroups":[{"name":"Readers","tags":["ReaderCheckouts"]}],
	  "paths":{"/readers/checkouts":{"post":{"operationId":"CreateReaderCheckout",
	    "tags":["ReaderCheckouts"],"x-codegen":{"method_name":"create_checkout"},
	    "responses":{"204":{"description":"OK"}}}}}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	g, err := newGenerator(spec)
	if err != nil {
		t.Fatal(err)
	}
	files := generatedFiles(t, g)
	parent := files["lib/sumup/resources/readers.rb"]
	contains(t, parent, "@checkouts ||= ReaderCheckouts.new(@client)")
	contains(t, parent, "def create_checkout(")
	contains(t, files["lib/sumup/resources/reader_checkouts.rb"], "def create_checkout(")
	contains(t, files["sig/sumup/resources/readers.rbs"], "def checkouts: () -> ReaderCheckouts")
	if got := g.resourcePath("ReaderCheckouts"); got != "readers.checkouts" {
		t.Fatalf("wrong sample resource path %q", got)
	}
}

func TestSchemaTypes(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, schemas string
		ruby, rbs     []string
	}{
		{"described references and annotation allOf", `{"Amount":{"type":"integer"},"Amounts":{"type":"array","items":{"$ref":"#/components/schemas/Amount"}},"Widget":{"type":"object","properties":{"amount":{"$ref":"#/components/schemas/Amount","description":"Amount"},"amounts":{"allOf":[{"$ref":"#/components/schemas/Amounts"}],"description":"Values"}}}}`, []string{"field :amount, :integer", "field :amounts, [:array, :integer]"}, []string{"attr_reader amounts: (Array[Integer])?"}},
		{"inheritance and recursion", `{"Base":{"type":"object","required":["id"],"properties":{"id":{"type":"string"}}},"Node":{"allOf":[{"$ref":"#/components/schemas/Base"},{"type":"object","properties":{"child":{"$ref":"#/components/schemas/Node"}}}]}}`, []string{`field :id, :string, wire: "id", required: true`, `field :child, [:model, "Node"]`}, nil},
		{"equivalent scalar aliases", `{"Amount":{"type":"integer"},"Count":{"type":"integer"},"Widget":{"properties":{"count":{"$ref":"#/components/schemas/Count"}}}}`, []string{"field :count, :integer"}, nil},
		{"nullable scalar and primitive union", `{"Widget":{"properties":{"optional":{"type":["string","null"]},"country":{"oneOf":[{"type":"string","enum":["DE"]},{"type":"string"}]}}}}`, []string{"field :optional, [:union, [:string, :nil]]", "field :country, [:union, [:string]]"}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			files := generatedFiles(t, fixture(t, tt.schemas, ""))
			for _, want := range tt.ruby {
				contains(t, files["lib/sumup/types.rb"], want)
			}
			for _, want := range tt.rbs {
				contains(t, files["sig/sumup/types.rbs"], want)
			}
		})
	}
}
func TestOperationParametersAndResponseTypes(t *testing.T) {
	t.Parallel()
	path := strings.Replace(widgetPath, `"get":{`, `"get":{"parameters":[{"name":"id","in":"path","required":true,"schema":{"type":"integer"}},{"name":"resource.id","in":"query","schema":{"type":"string"}}],`, 1)
	files := generatedFiles(t, fixture(t, "", path))
	source := files["lib/sumup/resources/widgets.rb"]
	contains(t, source, "def get(id:, resource_id: UNSET, options: nil)")
	contains(t, source, `"resource.id" => resource_id`)
	contains(t, source, "response_type: {200 => [:map, :any]}")
	contains(t, files["sig/sumup/resources/widgets.rbs"], "id: Integer")
}
func TestExternalReferencesFail(t *testing.T) {
	t.Parallel()
	spec, err := decode(strings.NewReader(`{"components":{"schemas":{"Widget":{"$ref":"https://example.com/schema"}}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := newGenerator(spec); err == nil || !strings.Contains(err.Error(), "local references") {
		t.Fatalf("expected local reference error, got %v", err)
	}
}
func TestWriteFiles(t *testing.T) {
	t.Parallel()
	g := fixture(t, "", "")
	files := generatedFiles(t, g)
	if !reflect.DeepEqual(files, generatedFiles(t, g)) {
		t.Fatal("generation is not deterministic")
	}
	root := t.TempDir()
	if err := writeFiles(root, files, false); err != nil {
		t.Fatal(err)
	}
	for path, want := range files {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != want {
			t.Fatalf("written bytes differ for %s", path)
		}
	}
	if err := writeFiles(root, files, true); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(root, "lib", "sumup", "resources", "stale.rb")
	if err := os.WriteFile(stale, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeFiles(root, files, true); err == nil {
		t.Fatal("check accepted a stale file")
	}
	if err := writeFiles(root, files, false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatalf("stale file still exists: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "lib", "sumup", "types.rb"), []byte("changed"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeFiles(root, files, true); err == nil {
		t.Fatal("check accepted a changed file")
	}
}
func TestCurrentSpec(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile("../openapi.json")
	if err != nil {
		t.Fatal(err)
	}
	spec, err := decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	g, err := newGenerator(spec)
	if err != nil {
		t.Fatal(err)
	}
	files := generatedFiles(t, g)
	contains(t, files["sig/sumup/resources/readers.rbs"], "body: Types::CreateReaderCheckoutRequest | Hash[Symbol | String, untyped]")
	refundSignature := files["sig/sumup/resources/transactions.rbs"]
	contains(t, refundSignature, "?body: Types::RefundTransactionRequest | Hash[Symbol | String, untyped]")
	if strings.Contains(refundSignature, "?amount:") {
		t.Fatal("refund signature accepts body keywords")
	}
	expected := []string{}
	for _, path := range asObject(spec.get("paths")) {
		for _, entry := range asObject(path.value) {
			if slices.Contains(methods, entry.key) {
				expected = append(expected, asString(asObject(entry.value).get("operationId")))
			}
		}
	}
	actual := []string{}
	for _, op := range g.operations {
		actual = append(actual, op.id)
	}
	slices.Sort(expected)
	slices.Sort(actual)
	if !slices.Equal(expected, actual) {
		t.Fatal("generated operation IDs differ from spec")
	}
	if len(g.events()) != len(asObject(spec.get("webhooks"))) {
		t.Fatal("generated events differ from spec")
	}
	if err := writeFiles("..", files, true); err != nil {
		t.Fatal(err)
	}
}
func TestSamplesCommand(t *testing.T) {
	t.Parallel()
	var stdout bytes.Buffer
	if err := run([]string{"samples", "--out", "-"}, strings.NewReader(""), &stdout); err != nil {
		t.Fatal(err)
	}
	var output catalog
	if err := json.Unmarshal(stdout.Bytes(), &output); err != nil {
		t.Fatal(err)
	}
	if output.SchemaVersion != 1 || output.Language != "ruby" || output.SDK.Version == "" || len(output.Samples) == 0 {
		t.Fatalf("invalid catalogue metadata: %+v", output.SDK)
	}
	// Every operation has at least one sample, including all named request examples.
	data, err := os.ReadFile("../openapi.json")
	if err != nil {
		t.Fatal(err)
	}
	spec, err := decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	g, err := newGenerator(spec)
	if err != nil {
		t.Fatal(err)
	}
	ids := map[string]bool{}
	for _, s := range output.Samples {
		ids[s.OperationID] = true
	}
	if len(ids) != len(g.operations) {
		t.Fatal("sample catalogue omits operations")
	}
}
func TestRubyStringLiteralsEscapeInterpolation(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"#{user}", "#@instance", "#$global"} {
		if !strings.Contains(quote(value), `\#`) {
			t.Fatalf("unescaped interpolation in %q", quote(value))
		}
	}
}
