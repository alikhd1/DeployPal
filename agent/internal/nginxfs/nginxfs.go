// Nginx filesystem operations. The agent reads raw configs (the orchestrator
// parses them) and performs validated writes/symlinks/reloads.
package nginxfs

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	sitesAvailable = "/etc/nginx/sites-available"
	sitesEnabled   = "/etc/nginx/sites-enabled"
	// Every file we write starts with this header; we refuse to overwrite or
	// disable any site that lacks it (i.e. anything a human wrote by hand).
	managedHeader = "# managed-by: smise-navi"
)

var safeFilename = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,80}\.conf$`)

type Site struct {
	Path    string
	Enabled bool
	Managed bool
	Content string
	MTime   int64
}

func ListSites() ([]Site, error) {
	enabled := map[string]bool{}
	if links, err := os.ReadDir(sitesEnabled); err == nil {
		for _, l := range links {
			target, err := os.Readlink(filepath.Join(sitesEnabled, l.Name()))
			if err == nil {
				enabled[filepath.Base(target)] = true
			} else {
				enabled[l.Name()] = true // plain file, not a symlink
			}
		}
	}

	files, err := os.ReadDir(sitesAvailable)
	if err != nil {
		return nil, err
	}
	var out []Site
	for _, f := range files {
		if f.IsDir() {
			continue
		}
		full := filepath.Join(sitesAvailable, f.Name())
		b, err := os.ReadFile(full)
		if err != nil {
			continue
		}
		info, _ := f.Info()
		var mtime int64
		if info != nil {
			mtime = info.ModTime().Unix()
		}
		out = append(out, Site{
			Path:    full,
			Enabled: enabled[f.Name()],
			Managed: strings.HasPrefix(string(b), managedHeader),
			Content: string(b),
			MTime:   mtime,
		})
	}
	return out, nil
}

// WriteSite atomically writes a managed site file. Refuses path tricks and
// refuses to clobber an unmanaged (hand-written) config.
func WriteSite(filename, content string) error {
	if !safeFilename.MatchString(filename) {
		return fmt.Errorf("invalid site filename %q", filename)
	}
	if !strings.HasPrefix(content, managedHeader) {
		return fmt.Errorf("content must start with %q", managedHeader)
	}
	target := filepath.Join(sitesAvailable, filename)
	if existing, err := os.ReadFile(target); err == nil {
		if !strings.HasPrefix(string(existing), managedHeader) {
			return fmt.Errorf("%s exists and is not managed by smise-navi; refusing to overwrite", filename)
		}
	}
	tmp := target + fmt.Sprintf(".tmp.%d", time.Now().UnixNano())
	if err := os.WriteFile(tmp, []byte(content), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, target)
}

func EnableSite(filename string) error {
	if !safeFilename.MatchString(filename) {
		return fmt.Errorf("invalid site filename %q", filename)
	}
	link := filepath.Join(sitesEnabled, filename)
	if _, err := os.Lstat(link); err == nil {
		return nil // already enabled
	}
	return os.Symlink(filepath.Join(sitesAvailable, filename), link)
}

func DisableSite(filename string) error {
	if !safeFilename.MatchString(filename) {
		return fmt.Errorf("invalid site filename %q", filename)
	}
	// Only remove the symlink for managed sites.
	b, err := os.ReadFile(filepath.Join(sitesAvailable, filename))
	if err == nil && !strings.HasPrefix(string(b), managedHeader) {
		return fmt.Errorf("%s is not managed by smise-navi; refusing to disable", filename)
	}
	err = os.Remove(filepath.Join(sitesEnabled, filename))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// TestConfig runs `nginx -t`; its stderr is the payload the UI shows on failure.
func TestConfig() (bool, string) {
	out, err := exec.Command("/usr/sbin/nginx", "-t").CombinedOutput()
	return err == nil, string(out)
}

// Reload sends SIGHUP via nginx -s reload (graceful; workers finish in-flight
// requests). Callers must run TestConfig first.
func Reload() (bool, string) {
	out, err := exec.Command("/usr/sbin/nginx", "-s", "reload").CombinedOutput()
	return err == nil, string(out)
}

// ObtainCertificate invokes certbot with a fixed argument template — domains
// are validated, nothing else is caller-controlled.
var safeDomain = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$`)

func ObtainCertificate(domains []string, email string) (bool, string) {
	if len(domains) == 0 {
		return false, "no domains"
	}
	args := []string{"--nginx", "--non-interactive", "--agree-tos", "--email", email}
	for _, d := range domains {
		if !safeDomain.MatchString(d) {
			return false, fmt.Sprintf("invalid domain %q", d)
		}
		args = append(args, "-d", d)
	}
	out, err := exec.Command("/usr/bin/certbot", args...).CombinedOutput()
	return err == nil, string(out)
}
