package recipes

import (
	"strconv"
	"strings"
	"testing"
	"text/template"
)

// The builtin catalog must always parse, validate, and render — a YAML typo
// here would otherwise only surface at runtime on a production host.
func TestBuiltinCatalog(t *testing.T) {
	cat, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(cat.Recipes) < 15 {
		t.Fatalf("suspiciously small catalog: %d recipes", len(cat.Recipes))
	}
	if cat.Version == "" {
		t.Fatal("empty catalog version")
	}

	seen := map[string]bool{}
	for _, r := range cat.Recipes {
		if seen[r.ID] {
			t.Errorf("duplicate recipe id %q", r.ID)
		}
		seen[r.ID] = true

		// Every config template must render against the recipe's own defaults.
		if r.Config != nil {
			rr := r
			rr.Resolve(HostFacts{MemTotalBytes: 8 << 30})
			params, _, err := rr.ValidateParams(nil)
			if err != nil {
				t.Errorf("%s: defaults do not validate: %v", r.ID, err)
				continue
			}
			tpl, err := template.New(r.ID).Option("missingkey=error").Parse(r.Config.Template)
			if err != nil {
				t.Errorf("%s: bad template: %v", r.ID, err)
				continue
			}
			var out strings.Builder
			if err := tpl.Execute(&out, params); err != nil {
				t.Errorf("%s: template does not render with defaults: %v", r.ID, err)
			}
		}
	}
	for _, id := range []string{"postgresql", "redis", "mysql", "mariadb", "rabbitmq", "htop", "fail2ban"} {
		if !seen[id] {
			t.Errorf("expected recipe %q in builtin catalog", id)
		}
	}
}

func TestDerivedDefaults(t *testing.T) {
	cat, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	pg := cat.Get("postgresql")
	if pg == nil {
		t.Fatal("no postgresql recipe")
	}
	r := *pg
	r.Resolve(HostFacts{MemTotalBytes: 16 << 30}) // 16 GiB → shared_buffers 4096 MB
	for _, p := range r.Params {
		if p.Name == "shared_buffers_mb" {
			n, _ := strconv.Atoi(p.Default)
			if n != 4096 {
				t.Errorf("shared_buffers_mb = %d, want 4096", n)
			}
			if p.DerivedHint == "" {
				t.Error("derived param has no hint")
			}
		}
	}
}

func TestValidateParamsRejectsBadInput(t *testing.T) {
	cat, _ := Load()
	pg := cat.Get("postgresql")
	cases := []map[string]string{
		{"listen": "everywhere"}, // not in enum
		{"port": "notaport"},     // not an int
		{"port": "70000"},        // out of range
		{"max_connections": "3"}, // below min
		{"no_such_param": "x"},   // unknown name
	}
	for _, in := range cases {
		if _, _, err := pg.ValidateParams(in); err == nil {
			t.Errorf("ValidateParams(%v) accepted bad input", in)
		}
	}
	if _, _, err := pg.ValidateParams(map[string]string{"port": "5433", "listen": "all"}); err != nil {
		t.Errorf("valid params rejected: %v", err)
	}
}
