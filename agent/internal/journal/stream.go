// journald streaming via a `journalctl -o json` subprocess.
//
// Why a subprocess and not cgo sdjournal: journalctl gives us the same unit
// filtering, tail backfill, --after-cursor resumption, and follow mode, while
// keeping the agent pure Go (CGO_ENABLED=0) — a single static binary with no
// libsystemd linkage, cross-compilable from any platform. This is the same
// trade Vector makes. One short-lived pipe per active log stream is noise
// compared to the log volume itself.
package journal

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
)

type Line struct {
	TSMicros int64
	Priority int32 // syslog 0-7, -1 if the field is absent
	Message  string
	Cursor   string
}

type StreamOpts struct {
	Unit      string // required: journalctl -u filter
	TailLines uint32 // backfill before following
	Follow    bool
	Cursor    string // resume point from a previous stream; "" = start from tail
}

var validUnit = regexp.MustCompile(`^[A-Za-z0-9:_.\\-]+\.(service|scope)$`)

// Stream sends journal lines to out until ctx is cancelled (or history is
// exhausted when Follow=false). Closes nothing; the caller owns `out`.
func Stream(ctx context.Context, opts StreamOpts, out chan<- Line) error {
	if !validUnit.MatchString(opts.Unit) {
		return fmt.Errorf("invalid unit %q", opts.Unit)
	}
	args := []string{"--no-pager", "-o", "json", "-u", opts.Unit}
	switch {
	case opts.Cursor != "":
		args = append(args, "--after-cursor", opts.Cursor)
	case opts.TailLines > 0:
		args = append(args, "-n", strconv.FormatUint(uint64(opts.TailLines), 10))
	default:
		args = append(args, "-n", "0")
	}
	if opts.Follow {
		args = append(args, "-f")
	}

	cmd := exec.CommandContext(ctx, "journalctl", args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start journalctl: %w", err)
	}
	defer cmd.Wait() // CommandContext kills the process on ctx cancel

	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024) // journal lines can be large
	for sc.Scan() {
		line, ok := parseEntry(sc.Bytes())
		if !ok {
			continue
		}
		select {
		case out <- line:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return sc.Err()
}

// parseEntry decodes one journalctl JSON object. MESSAGE is usually a string,
// but journald encodes non-UTF8 payloads as an array of byte values.
func parseEntry(raw []byte) (Line, bool) {
	var entry map[string]any
	if err := json.Unmarshal(raw, &entry); err != nil {
		return Line{}, false
	}
	line := Line{Priority: -1}
	if c, ok := entry["__CURSOR"].(string); ok {
		line.Cursor = c
	}
	if ts, ok := entry["__REALTIME_TIMESTAMP"].(string); ok {
		line.TSMicros, _ = strconv.ParseInt(ts, 10, 64)
	}
	if p, ok := entry["PRIORITY"].(string); ok {
		if n, err := strconv.Atoi(p); err == nil && n >= 0 && n <= 7 {
			line.Priority = int32(n)
		}
	}
	switch msg := entry["MESSAGE"].(type) {
	case string:
		line.Message = msg
	case []any: // byte-array form
		b := make([]byte, 0, len(msg))
		for _, v := range msg {
			if f, ok := v.(float64); ok {
				b = append(b, byte(f))
			}
		}
		line.Message = string(b)
	default:
		return Line{}, false
	}
	return line, true
}
