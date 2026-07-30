// recipes: the agent-owned service catalog.
//
// The catalog is the security boundary for package installation: the
// orchestrator can only name a recipe id and supply typed params — every
// package name, apt argument, and config file path comes from a recipe the
// host's root user shipped or approved. Two sources:
//
//   - builtin: YAML files embedded in the binary (go:embed). Upgrading the
//     agent upgrades the catalog — no separate distribution step.
//   - overlay: /etc/deploypal/recipes/*.yaml, root-owned. Re-read on every
//     Load() so an admin can drop in a recipe without restarting the agent.
//     An overlay recipe with an existing id replaces the builtin one.
package recipes

import (
	"crypto/sha256"
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

//go:embed catalog/*.yaml
var builtinFS embed.FS

const OverlayDir = "/etc/deploypal/recipes"

var idRx = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,40}$`)

// Derive computes a param default from a host fact at list time.
type Derive struct {
	Source string  `yaml:"source"` // only "mem_mb" for now
	Factor float64 `yaml:"factor"`
	Min    int64   `yaml:"min"`
	Max    int64   `yaml:"max"`
}

type Param struct {
	Name       string   `yaml:"name"`
	Type       string   `yaml:"type"` // enum | int | port | string | secret
	Default    string   `yaml:"default"`
	Values     []string `yaml:"values"`
	Min        int64    `yaml:"min"`
	Max        int64    `yaml:"max"`
	Required   bool     `yaml:"required"`
	Advanced   bool     `yaml:"advanced"`
	UnitSuffix string   `yaml:"unit_suffix"`
	Derive     *Derive  `yaml:"derive"`

	// filled by Resolve():
	DerivedHint string `yaml:"-"`
}

type Config struct {
	// Path of the managed file the recipe writes. May contain a glob (*)
	// that is resolved after the packages are installed (e.g. the postgres
	// version directory). Always additive: a drop-in / included file, never
	// the distro's main config.
	Path        string `yaml:"path"`
	Mode        string `yaml:"mode"`         // default 0644
	Owner       string `yaml:"owner"`        // "user:group", default root:root
	IncludeInto string `yaml:"include_into"` // append IncludeLine to this file (marker-guarded)
	IncludeLine string `yaml:"include_line"`
	Template    string `yaml:"template"` // Go text/template over the param map
}

type Recipe struct {
	ID          string   `yaml:"id"`
	Kind        string   `yaml:"kind"` // dependencies.kind value, or "tool"
	Name        string   `yaml:"name"`
	Description string   `yaml:"description"`
	Unit        string   `yaml:"unit"`
	DefaultPort uint32   `yaml:"default_port"`
	Packages    []string `yaml:"packages"`
	Conflicts   []string `yaml:"conflicts"` // recipe ids that must not be installed
	Params      []Param  `yaml:"params"`
	Config      *Config  `yaml:"config"`
	VerifyPort  bool     `yaml:"verify_port"` // TCP-dial the port param after restart

	Source string `yaml:"-"` // builtin | overlay
}

// recipeFile lets one YAML file hold either a single recipe or a list.
type recipeFile struct {
	Recipes []Recipe `yaml:"recipes"`
}

type Catalog struct {
	Recipes []Recipe
	Version string // sha256 over all recipe bytes — changes on upgrade or overlay edit
}

func (c *Catalog) Get(id string) *Recipe {
	for i := range c.Recipes {
		if c.Recipes[i].ID == id {
			return &c.Recipes[i]
		}
	}
	return nil
}

// Units returns every systemd unit the catalog manages; the systemd action
// allow-list is derived from this, so installing a service automatically
// makes it controllable from the dashboard.
func (c *Catalog) Units() []string {
	var out []string
	for _, r := range c.Recipes {
		if r.Unit != "" {
			out = append(out, r.Unit)
		}
	}
	return out
}

var (
	builtinOnce    sync.Once
	builtinRecipes []Recipe
	builtinErr     error
	builtinHash    []byte
)

// Load returns builtin recipes merged with the overlay dir. The overlay is
// re-read on every call so catalog edits show up without an agent restart.
func Load() (*Catalog, error) {
	builtinOnce.Do(loadBuiltin)
	if builtinErr != nil {
		return nil, builtinErr
	}

	byID := map[string]int{}
	recipes := make([]Recipe, len(builtinRecipes))
	copy(recipes, builtinRecipes)
	for i, r := range recipes {
		byID[r.ID] = i
	}

	h := sha256.New()
	h.Write(builtinHash)

	entries, err := os.ReadDir(OverlayDir)
	if err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("overlay dir: %w", err)
	}
	for _, e := range entries {
		if e.IsDir() || (!strings.HasSuffix(e.Name(), ".yaml") && !strings.HasSuffix(e.Name(), ".yml")) {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(OverlayDir, e.Name()))
		if err != nil {
			return nil, fmt.Errorf("overlay %s: %w", e.Name(), err)
		}
		h.Write(raw)
		parsed, err := parse(raw, "overlay")
		if err != nil {
			return nil, fmt.Errorf("overlay %s: %w", e.Name(), err)
		}
		for _, r := range parsed {
			if i, dup := byID[r.ID]; dup {
				recipes[i] = r // overlay overrides builtin
			} else {
				byID[r.ID] = len(recipes)
				recipes = append(recipes, r)
			}
		}
	}

	sort.Slice(recipes, func(i, j int) bool { return recipes[i].ID < recipes[j].ID })
	return &Catalog{Recipes: recipes, Version: fmt.Sprintf("%x", h.Sum(nil))[:16]}, nil
}

func loadBuiltin() {
	entries, err := builtinFS.ReadDir("catalog")
	if err != nil {
		builtinErr = err
		return
	}
	h := sha256.New()
	for _, e := range entries {
		raw, err := builtinFS.ReadFile("catalog/" + e.Name())
		if err != nil {
			builtinErr = err
			return
		}
		h.Write(raw)
		parsed, err := parse(raw, "builtin")
		if err != nil {
			builtinErr = fmt.Errorf("builtin %s: %w", e.Name(), err)
			return
		}
		builtinRecipes = append(builtinRecipes, parsed...)
	}
	builtinHash = h.Sum(nil)
}

func parse(raw []byte, source string) ([]Recipe, error) {
	var file recipeFile
	if err := yaml.Unmarshal(raw, &file); err != nil {
		return nil, err
	}
	recipes := file.Recipes
	if len(recipes) == 0 { // single-recipe file
		var one Recipe
		if err := yaml.Unmarshal(raw, &one); err != nil {
			return nil, err
		}
		if one.ID == "" {
			return nil, fmt.Errorf("no recipes found")
		}
		recipes = []Recipe{one}
	}
	for i := range recipes {
		recipes[i].Source = source
		if err := validate(&recipes[i]); err != nil {
			return nil, fmt.Errorf("recipe %q: %w", recipes[i].ID, err)
		}
	}
	return recipes, nil
}

var pkgRx = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]{1,80}$`) // Debian package name policy

func validate(r *Recipe) error {
	if !idRx.MatchString(r.ID) {
		return fmt.Errorf("invalid id")
	}
	if len(r.Packages) == 0 {
		return fmt.Errorf("no packages")
	}
	for _, p := range r.Packages {
		if !pkgRx.MatchString(p) {
			return fmt.Errorf("invalid package name %q", p)
		}
	}
	if r.Unit != "" && !strings.HasSuffix(r.Unit, ".service") {
		return fmt.Errorf("unit must end in .service")
	}
	if r.Config != nil {
		if !strings.HasPrefix(r.Config.Path, "/etc/") {
			return fmt.Errorf("config path must live under /etc/")
		}
		if r.Config.IncludeInto != "" && (r.Config.IncludeLine == "" || !strings.HasPrefix(r.Config.IncludeInto, "/etc/")) {
			return fmt.Errorf("include_into requires include_line and an /etc/ path")
		}
	}
	seen := map[string]bool{}
	for _, p := range r.Params {
		if !idRx.MatchString(strings.ReplaceAll(p.Name, "_", "-")) || seen[p.Name] {
			return fmt.Errorf("bad or duplicate param %q", p.Name)
		}
		seen[p.Name] = true
		switch p.Type {
		case "enum":
			if len(p.Values) == 0 {
				return fmt.Errorf("enum param %q has no values", p.Name)
			}
		case "int", "port", "string", "secret":
		default:
			return fmt.Errorf("param %q: unknown type %q", p.Name, p.Type)
		}
	}
	return nil
}

// HostFacts feed derived defaults; the server fills this from sysinfo.
type HostFacts struct {
	MemTotalBytes uint64
}

// Resolve computes derived defaults into Param.Default (+ DerivedHint) so the
// UI can show ready-to-use values.
func (r *Recipe) Resolve(f HostFacts) {
	for i := range r.Params {
		p := &r.Params[i]
		if p.Derive == nil || p.Derive.Source != "mem_mb" {
			continue
		}
		v := int64(float64(f.MemTotalBytes) / (1 << 20) * p.Derive.Factor)
		if p.Derive.Min > 0 && v < p.Derive.Min {
			v = p.Derive.Min
		}
		if p.Derive.Max > 0 && v > p.Derive.Max {
			v = p.Derive.Max
		}
		p.Default = strconv.FormatInt(v, 10)
		p.DerivedHint = fmt.Sprintf("%.0f%% of %.1f GiB RAM",
			p.Derive.Factor*100, float64(f.MemTotalBytes)/(1<<30))
	}
}

// ValidateParams checks user-supplied values against the schema and returns
// the complete param map (defaults applied, secrets generated).
// generated maps param name → freshly generated secret value.
func (r *Recipe) ValidateParams(in map[string]string) (values, generated map[string]string, err error) {
	values, generated = map[string]string{}, map[string]string{}
	known := map[string]bool{}
	for _, p := range r.Params {
		known[p.Name] = true
		v, given := in[p.Name]
		if !given || v == "" {
			v = p.Default
		}
		switch p.Type {
		case "enum":
			okv := false
			for _, allowed := range p.Values {
				if v == allowed {
					okv = true
					break
				}
			}
			if !okv {
				return nil, nil, fmt.Errorf("param %s: %q not in %v", p.Name, v, p.Values)
			}
		case "int", "port":
			n, convErr := strconv.ParseInt(v, 10, 64)
			if convErr != nil {
				return nil, nil, fmt.Errorf("param %s: %q is not an integer", p.Name, v)
			}
			lo, hi := p.Min, p.Max
			if p.Type == "port" {
				if lo == 0 {
					lo = 1
				}
				if hi == 0 {
					hi = 65535
				}
			}
			if (lo != 0 && n < lo) || (hi != 0 && n > hi) {
				return nil, nil, fmt.Errorf("param %s: %d outside [%d, %d]", p.Name, n, lo, hi)
			}
		case "secret":
			if v == "" && p.Required {
				secret, genErr := randomSecret(24)
				if genErr != nil {
					return nil, nil, genErr
				}
				v, generated[p.Name] = secret, secret
			}
		case "string":
			if len(v) > 256 || strings.ContainsAny(v, "\n\r\x00") {
				return nil, nil, fmt.Errorf("param %s: invalid string", p.Name)
			}
		}
		if v == "" && p.Required {
			return nil, nil, fmt.Errorf("param %s is required", p.Name)
		}
		values[p.Name] = v
	}
	for name := range in {
		if !known[name] {
			return nil, nil, fmt.Errorf("unknown param %q", name)
		}
	}
	return values, generated, nil
}
