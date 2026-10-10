package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeDaemon answers one connection with a canned reply and reports the
// request it received. The socket lives in /tmp rather than t.TempDir()
// because Unix socket paths are capped at about 100 bytes on macOS.
func fakeDaemon(t *testing.T, reply string) (string, chan map[string]any) {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "sym-cli-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "service.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	requests := make(chan map[string]any, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request map[string]any
		if err := json.NewDecoder(conn).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		requests <- request
		conn.Write([]byte(reply + "\n"))
	}()
	return socket, requests
}

// The CLI must send exactly the wire request for each command shape, and the
// default output must be plain location lines an agent can parse like grep's.
func TestSemanticRequestsAndLineOutput(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	here := func(name string) string { return filepath.Join(cwd, name) }
	cases := []struct {
		name    string
		args    []string
		reply   string
		request map[string]any
		stdout  string
	}{
		{
			name: "refs by name with a single match prints plain lines",
			args: []string{"refs", "createMidiScheduler"},
			reply: `{"ok":true,"result":{"matches":[{"symbol":{"name":"createMidiScheduler","kind":"function","path":"` +
				here("src/foo.ts") + `","line":3,"column":10},"refs":[{"path":"` + here("src/foo.ts") +
				`","line":17,"column":5},{"path":"` + here("src/bar.ts") + `","line":82,"column":11}]}]}}`,
			request: map[string]any{"op": "refs", "name": "createMidiScheduler"},
			stdout:  "src/foo.ts:17:5\nsrc/bar.ts:82:11\n",
		},
		{
			name: "refs with several matches groups per symbol",
			args: []string{"refs", "parse"},
			reply: `{"ok":true,"result":{"matches":[` +
				`{"symbol":{"name":"parse","kind":"function","path":"/elsewhere/a.ts","line":1,"column":10},"refs":[{"path":"/elsewhere/b.ts","line":2,"column":3}]},` +
				`{"symbol":{"name":"parse","kind":"method","container":"Parser","path":"/elsewhere/a.ts","line":9,"column":3},"refs":[]}]}}`,
			request: map[string]any{"op": "refs", "name": "parse"},
			stdout: "parse (function) /elsewhere/a.ts:1:10\n  /elsewhere/b.ts:2:3\n\n" +
				"Parser.parse (method) /elsewhere/a.ts:9:3\n",
		},
		{
			name:    "refs at a location parses FILE:LINE:COL from the right",
			args:    []string{"refs", "--at", "src/parser.ts:42:8"},
			reply:   `{"ok":true,"result":{"matches":[{"refs":[]}]}}`,
			request: map[string]any{"op": "refs", "path": here("src/parser.ts"), "line": float64(42), "column": float64(8)},
			stdout:  "",
		},
		{
			name:    "def by name describes each definition",
			args:    []string{"def", "parse"},
			reply:   `{"ok":true,"result":{"definitions":[{"name":"parse","kind":"method","container":"Parser","path":"/elsewhere/a.ts","line":9,"column":3}]}}`,
			request: map[string]any{"op": "def", "name": "parse"},
			stdout:  "/elsewhere/a.ts:9:3\tParser.parse (method)\n",
		},
		{
			name:    "def at a location prints bare places",
			args:    []string{"def", "--at", "/abs/foo.ts:73:12"},
			reply:   `{"ok":true,"result":{"definitions":[{"path":"/elsewhere/a.ts","line":9,"column":3}]}}`,
			request: map[string]any{"op": "def", "path": "/abs/foo.ts", "line": float64(73), "column": float64(12)},
			stdout:  "/elsewhere/a.ts:9:3\n",
		},
		{
			name:    "symbols sends an absolute path and describes results",
			args:    []string{"symbols", "src/parser.ts"},
			reply:   `{"ok":true,"result":{"symbols":[{"name":"parse","kind":"function","path":"/elsewhere/a.ts","line":1,"column":10}]}}`,
			request: map[string]any{"op": "symbols", "path": here("src/parser.ts")},
			stdout:  "/elsewhere/a.ts:1:10\tparse (function)\n",
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			socket, requests := fakeDaemon(t, test.reply)
			var stdout, stderr bytes.Buffer
			if code := run(append([]string{"--socket", socket}, test.args...), &stdout, &stderr); code != 0 {
				t.Fatalf("exit %d: %s", code, &stderr)
			}
			if request := <-requests; !mapsEqual(request, test.request) {
				t.Fatalf("unexpected request: %#v, want %#v", request, test.request)
			}
			if stdout.String() != test.stdout {
				t.Fatalf("unexpected output:\n%q\nwant:\n%q", stdout.String(), test.stdout)
			}
		})
	}
}

func mapsEqual(got, want map[string]any) bool {
	if len(got) != len(want) {
		return false
	}
	for key, value := range want {
		if got[key] != value {
			return false
		}
	}
	return true
}

// --json prints the result object exactly as symd sent it, so agents parse
// one stable shape instead of scraping formatted lines.
func TestJSONPassesTheResultThrough(t *testing.T) {
	result := `{"matches":[{"refs":[{"path":"/x/a.ts","line":1,"column":2}]}]}`
	socket, requests := fakeDaemon(t, `{"ok":true,"result":`+result+`}`)
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--socket", socket, "--json", "refs", "--at", "/x/a.ts:1:2"}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d: %s", code, &stderr)
	}
	<-requests
	if stdout.String() != result+"\n" {
		t.Fatalf("unexpected output: %q", stdout.String())
	}
}

// An ambiguous name is still an answer — the candidates — but with its own
// exit code so an agent knows to narrow and re-ask rather than parse refs.
func TestAmbiguousNamesExitThree(t *testing.T) {
	reply := `{"ok":true,"result":{"candidates":[` +
		`{"name":"parse","kind":"function","path":"/x/a.ts","line":1,"column":10},` +
		`{"name":"parse","kind":"method","container":"Parser","path":"/x/b.ts","line":9,"column":3}]}}`
	socket, requests := fakeDaemon(t, reply)
	var stdout, stderr bytes.Buffer
	code := run([]string{"--socket", socket, "refs", "parse"}, &stdout, &stderr)
	<-requests
	if code != 3 {
		t.Fatalf("exit %d: %s", code, &stderr)
	}
	if !strings.Contains(stderr.String(), "matches 2 symbols") {
		t.Fatalf("missing ambiguity explanation: %s", &stderr)
	}
	want := "/x/a.ts:1:10\tparse (function)\n/x/b.ts:9:3\tParser.parse (method)\n"
	if stdout.String() != want {
		t.Fatalf("unexpected candidates: %q", stdout.String())
	}
}

func TestSemanticErrorsReachStderr(t *testing.T) {
	reply := `{"ok":false,"error":{"code":"symbol_not_found","message":"no symbol named \"zzz\""}}`
	socket, requests := fakeDaemon(t, reply)
	var stdout, stderr bytes.Buffer
	code := run([]string{"--socket", socket, "def", "zzz"}, &stdout, &stderr)
	<-requests
	if code != 1 || stdout.Len() != 0 {
		t.Fatalf("exit %d with output %q", code, stdout.String())
	}
	if !strings.Contains(stderr.String(), "symbol_not_found") || !strings.Contains(stderr.String(), "zzz") {
		t.Fatalf("unhelpful error: %s", &stderr)
	}
}

// No socket or service is set up here, so if any of these reached the network
// they'd fail with exit 1 instead of the usage exit 2.
func TestInvalidArgumentsDoNotSendRequests(t *testing.T) {
	for _, args := range [][]string{
		{}, {"refs"}, {"def"}, {"symbols"}, {"list"},
		{"refs", "a", "b"}, {"refs", "--at", "src/a.ts:1:2", "extra"},
		{"refs", "--at", "nocolons"}, {"def", "--at", "src/a.ts:0:2"},
		{"def", "--at", "src/a.ts:1:x"}, {"def", "--at", ":1:2"},
		{"symbols", "a", "b"}, {"start", "extra"}, {"status", "extra"},
	} {
		var stdout, stderr bytes.Buffer
		if code := run(args, &stdout, &stderr); code != 2 {
			t.Fatalf("%v: exit %d: %s", args, code, &stderr)
		}
	}
}

func TestMissingDaemonExplainsHowToStartIt(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "sym-missing-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	var stdout, stderr bytes.Buffer
	code := run([]string{"--socket", filepath.Join(dir, "missing.sock"), "refs", "parse"}, &stdout, &stderr)
	if code != 1 || !strings.Contains(stderr.String(), "sym start") {
		t.Fatalf("exit %d without startup guidance: %s", code, &stderr)
	}
}
