// Command logreplay turns a Game.log, or one of the made-up excerpts in
// tests/logs, into a recording that `bururu mod replay` plays: each line
// becomes a gamelog record at the time its own timestamp gives, counted from
// the first one. A line without a timestamp takes the time of the line
// before it.
//
// In an excerpt, a line starting with # is a comment, except these, which
// carry their own time:
//
//	# <2026-09-21T10:19:02.000Z> step: Take the pilot seat
//	# <2026-09-21T10:19:02.000Z> game: closed      (or: game: running)
//	# <2026-09-21T10:19:02.000Z> pad: {"r2": 255, "held": ["r2"]}
//
// A real Game.log holds your handle and other players' names: keep a
// recording made from one to yourself.
//
//	go run .github/logreplay/main.go -out tests/session.replay.jsonl tests/logs/session.log.txt
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
)

// the timestamp at the start of a Game.log line
var stampRE = regexp.MustCompile(`^<(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)>`)

// a directive in an excerpt: # <time> step|game|pad: text
var directiveRE = regexp.MustCompile(`^#\s*<([^>]+)>\s*(step|game|pad):\s*(.*)$`)

// a UTF-8 byte order mark, which a file may start with
const bom = "\xef\xbb\xbf"

type header struct {
	Replay      int    `json:"replay"`
	Mod         string `json:"mod"`
	ModVersion  string `json:"mod_version"`
	Bururu      string `json:"bururu"`
	StartUnixMs int64  `json:"start_unix_ms"`
	PollMs      int    `json:"poll_ms"`
}

type record struct {
	TMs     int64          `json:"t_ms"`
	Sensor  string         `json:"sensor,omitempty"`
	Raw     *string        `json:"raw,omitempty"`
	State   map[string]any `json:"state,omitempty"`
	Running *bool          `json:"running,omitempty"`
	InFront *bool          `json:"in_front,omitempty"`
	Step    *string        `json:"step,omitempty"`
}

func main() {
	out := flag.String("out", "", "the recording to write; default: standard output")
	mod := flag.String("mod", "starcitizen", "the mod id the recording is for")
	version := flag.String("version", "", "the mod version; default: manifest.json's in this folder")
	bururu := flag.String("bururu", "0.11.0", "the Bururu version the recording is made for")
	sensor := flag.String("sensor", "gamelog", "the sensor id of the log's lines")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: logreplay [-out file] <Game.log or excerpt>")
		os.Exit(2)
	}
	if *version == "" {
		*version = manifestVersion("manifest.json")
	}
	in, err := os.Open(flag.Arg(0))
	if err != nil {
		fail(err)
	}
	defer in.Close()
	var buf bytes.Buffer
	h := header{Replay: 1, Mod: *mod, ModVersion: *version, Bururu: *bururu, PollMs: 25}
	if err := convert(in, &buf, h, *sensor); err != nil {
		fail(fmt.Errorf("%s: %w", flag.Arg(0), err))
	}
	if *out == "" {
		os.Stdout.Write(buf.Bytes())
		return
	}
	if err := os.WriteFile(*out, buf.Bytes(), 0o644); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "logreplay:", err)
	os.Exit(1)
}

// manifestVersion is the version in a manifest, "0.0.0" without one. The
// manifest may hold // comments, so the version is found as text.
func manifestVersion(file string) string {
	b, err := os.ReadFile(file)
	if err != nil {
		return "0.0.0"
	}
	m := regexp.MustCompile(`"version"\s*:\s*"([^"]+)"`).FindSubmatch(b)
	if m == nil {
		return "0.0.0"
	}
	return string(m[1])
}

// convert writes the recording of the log in r to w: the header, the game
// running from the start, then a record per line and directive.
func convert(r io.Reader, w io.Writer, h header, sensor string) error {
	var recs []record
	var start, last time.Time
	started := false
	at := func(t time.Time) int64 {
		if !started {
			start, started = t, true
		}
		if t.Before(last) {
			t = last // a clock that steps back keeps the order
		}
		last = t
		return t.Sub(start).Milliseconds()
	}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 16<<20)
	n := 0
	for sc.Scan() {
		n++
		line := strings.TrimRight(sc.Text(), "\r")
		if n == 1 {
			line = strings.TrimPrefix(line, bom)
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			m := directiveRE.FindStringSubmatch(line)
			if m == nil {
				continue // a comment
			}
			t, err := time.Parse(time.RFC3339Nano, m[1])
			if err != nil {
				return fmt.Errorf("line %d: the time %q: %v", n, m[1], err)
			}
			rec := record{TMs: at(t)}
			arg := strings.TrimSpace(m[3])
			switch m[2] {
			case "step":
				rec.Step = &arg
			case "game":
				if arg != "running" && arg != "closed" {
					return fmt.Errorf("line %d: game: is running or closed", n)
				}
				on := arg == "running"
				rec.Sensor, rec.Running, rec.InFront = "game", &on, &on
			case "pad":
				rec.Sensor = "pad"
				if err := json.Unmarshal([]byte(arg), &rec.State); err != nil {
					return fmt.Errorf("line %d: pad: %v", n, err)
				}
				if rec.State == nil {
					rec.State = map[string]any{}
				}
			}
			recs = append(recs, rec)
			continue
		}
		t := last
		if m := stampRE.FindStringSubmatch(line); m != nil {
			p, err := time.Parse(time.RFC3339Nano, m[1])
			if err != nil {
				return fmt.Errorf("line %d: the time %q: %v", n, m[1], err)
			}
			t = p
		} else if !started {
			continue // lines before the first timestamp
		}
		raw := line
		recs = append(recs, record{TMs: at(t), Sensor: sensor, Raw: &raw})
	}
	if err := sc.Err(); err != nil {
		return err
	}
	if !started {
		return errors.New("no line with a timestamp")
	}
	h.StartUnixMs = start.UnixMilli()
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false) // the lines' <tags> stay readable
	if err := enc.Encode(h); err != nil {
		return err
	}
	on := true
	if err := enc.Encode(record{TMs: 0, Sensor: "game", Running: &on, InFront: &on}); err != nil {
		return err
	}
	for _, rec := range recs {
		if err := enc.Encode(rec); err != nil {
			return err
		}
	}
	return nil
}
