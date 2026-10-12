package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// request is the one JSON object we send to symd per invocation. A semantic
// request carries either a name or a path (symbols), or a path+line+column
// location, plus the caller's working directory — the daemon resolves the
// workspace from it. Management requests carry just the op.
type request struct {
	Op     string `json:"op"`
	Name   string `json:"name,omitempty"`
	Path   string `json:"path,omitempty"`
	Line   int    `json:"line,omitempty"`
	Column int    `json:"column,omitempty"`
	Cwd    string `json:"cwd,omitempty"`
}

// response mirrors symd's reply envelope: either ok=true with a result, or
// ok=false with an error. Result stays raw so the semantic formatting below
// can decode it, and --json can print it back exactly as symd sent it.
type response struct {
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

// main is a thin wrapper. It hands everything to run and exits with its code,
// so the real logic stays testable without calling os.Exit in a test.
func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

// run is the whole CLI: parse flags and the subcommand, build one request,
// send it to the daemon socket, then format the reply. Exit codes: 0 success,
// 1 symd or transport failure, 2 bad usage, 3 a name query too ambiguous to
// answer. Nothing is sent when the arguments are wrong.
func run(args []string, stdout, stderr io.Writer) int {
	// --feedback takes free text, or nothing at all to list what was written,
	// which the flag package can't express; it never reaches the daemon.
	if len(args) > 0 && (args[0] == "--feedback" || args[0] == "-feedback") {
		return feedback(args[1:], stdout, stderr)
	}
	flags := flag.NewFlagSet("sym", flag.ContinueOnError)
	flags.SetOutput(stderr)
	socket := flags.String("socket", defaultSocket(), "symd Unix socket")
	service := flags.String("service", siblingService(), "symd executable")
	asJSON := flags.Bool("json", false, "print the raw result object instead of location lines")
	source := flags.Bool("source", false, "print each reference's source line after its location, tab-separated")
	flags.Usage = func() {
		fmt.Fprintln(stderr, "Usage: sym [options] refs NAME | refs --at FILE:LINE:COL")
		fmt.Fprintln(stderr, "                     def NAME  | def --at FILE:LINE:COL")
		fmt.Fprintln(stderr, "                     symbols FILE")
		fmt.Fprintln(stderr, "                     start | status | stop")
		fmt.Fprintln(stderr, "       sym --feedback \"TEXT\"   note a wish or a problem with sym")
		fmt.Fprintln(stderr, "       sym --feedback          list the notes written so far")
		flags.PrintDefaults()
	}
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if flags.NArg() == 0 {
		flags.Usage()
		return 2
	}
	// Global flags stop at the first non-flag word, so everything after it is
	// the subcommand and its own arguments.
	command := flags.Args()
	var req request
	switch command[0] {
	case "def", "refs":
		locate := flag.NewFlagSet(command[0], flag.ContinueOnError)
		locate.SetOutput(stderr)
		at := locate.String("at", "", "FILE:LINE:COL")
		usage := func() int {
			fmt.Fprintf(stderr, "Usage: sym [options] %s NAME | %s --at FILE:LINE:COL\n", command[0], command[0])
			return 2
		}
		if err := locate.Parse(command[1:]); err != nil {
			return 2
		}
		switch {
		case *at != "" && locate.NArg() == 0:
			path, line, column, err := parseLocation(*at)
			if err != nil {
				fmt.Fprintf(stderr, "sym: %v\n", err)
				return 2
			}
			req = request{Op: command[0], Path: path, Line: line, Column: column}
		case *at == "" && locate.NArg() == 1:
			req = request{Op: command[0], Name: locate.Arg(0)}
		default:
			return usage()
		}
	case "symbols":
		if len(command) != 2 {
			fmt.Fprintln(stderr, "Usage: sym [options] symbols FILE")
			return 2
		}
		path, err := filepath.Abs(command[1])
		if err != nil {
			fmt.Fprintf(stderr, "sym: %v\n", err)
			return 2
		}
		req = request{Op: command[0], Path: path}
	case "start", "status", "stop":
		if len(command) != 1 {
			fmt.Fprintf(stderr, "Usage: sym [options] %s\n", command[0])
			return 2
		}
		req = request{Op: command[0]}
	default:
		flags.Usage()
		return 2
	}

	var reply response
	var err error
	switch req.Op {
	case "start":
		reply, err = startDaemon(*service, *socket)
	case "status":
		reply, err = daemonStatus(*socket, time.Second)
	case "stop":
		reply, err = stopDaemon(*socket)
	default:
		// The caller's directory picks the workspace; the daemon walks up
		// from it to the nearest sym.toml or repository root.
		req.Cwd, err = os.Getwd()
		if err != nil {
			fmt.Fprintf(stderr, "sym: %v\n", err)
			return 1
		}
		reply, err = semanticRequest(*service, *socket, req)
	}
	if err != nil {
		fmt.Fprintf(stderr, "sym: %v\n", err)
		return 1
	}
	switch req.Op {
	case "start", "status", "stop":
		// Management replies stay whole envelopes: scripts check their state.
		if err := json.NewEncoder(stdout).Encode(reply); err != nil {
			fmt.Fprintf(stderr, "sym: %v\n", err)
			return 1
		}
		if !reply.OK {
			return 1
		}
		return 0
	default:
		return printSemantic(req, reply, *asJSON, *source, stdout, stderr)
	}
}

// parseLocation splits FILE:LINE:COL from the right, so paths containing
// colons still work, and returns the file as an absolute path. Line and
// column are 1-based.
func parseLocation(location string) (string, int, int, error) {
	malformed := fmt.Errorf("expected FILE:LINE:COL with 1-based line and column, got %q", location)
	last := strings.LastIndex(location, ":")
	if last < 0 {
		return "", 0, 0, malformed
	}
	column, err := strconv.Atoi(location[last+1:])
	if err != nil || column < 1 {
		return "", 0, 0, malformed
	}
	rest := location[:last]
	last = strings.LastIndex(rest, ":")
	if last < 1 {
		return "", 0, 0, malformed
	}
	line, err := strconv.Atoi(rest[last+1:])
	if err != nil || line < 1 {
		return "", 0, 0, malformed
	}
	path, err := filepath.Abs(rest[:last])
	if err != nil {
		return "", 0, 0, err
	}
	return path, line, column, nil
}

// defaultSocket is one well-known, short path per user, the same from every
// directory: queries find the same daemon wherever they run, and macOS's
// ~104-byte socket path limit stays out of reach of deep project trees.
// SYM_SOCKET overrides it for scripts; --socket overrides both.
func defaultSocket() string {
	if path := os.Getenv("SYM_SOCKET"); path != "" {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "symd.sock")
	}
	return filepath.Join(home, ".sym", "symd.sock")
}

// siblingService points -service at a symd binary sitting next to sym itself,
// which is where `just build` puts both. If we can't find our own path, fall
// back to plain "symd" so the shell's PATH lookup takes over.
func siblingService() string {
	path, err := os.Executable()
	if err != nil {
		return "symd"
	}
	return filepath.Join(filepath.Dir(path), "symd")
}

// socketRequest sends one request line to the daemon and reads one reply line.
// The connection is closed when we're done, so every call is its own round trip.
// Only the dial has a timeout (3s); reading the reply has no deadline, because
// a cold language server may legitimately take a while to answer.
func socketRequest(path string, req request) (response, error) {
	reply, err := socketRequestWithin(path, req, 0)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED) {
		return response{}, fmt.Errorf("symd is not running at %s", path)
	}
	return reply, err
}

// Management probes have a short deadline; semantic requests keep their
// open-ended wait.
func socketRequestWithin(path string, req request, timeout time.Duration) (response, error) {
	conn, err := net.DialTimeout("unix", path, 3*time.Second)
	if err != nil {
		return response{}, err
	}
	defer conn.Close()
	if timeout > 0 {
		if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
			return response{}, err
		}
	}
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return response{}, err
	}
	return decodeResponse(conn)
}

// decodeResponse parses symd's reply and checks that it's a valid envelope. The
// reader is capped at 16 MiB so a runaway process can't make us read forever. We
// also reject replies that claim ok but have no result, or claim failure but
// have no error, because those can't be printed or explained to the user.
func decodeResponse(reader io.Reader) (response, error) {
	var reply response
	if err := json.NewDecoder(io.LimitReader(reader, 16*1024*1024)).Decode(&reply); err != nil {
		return reply, fmt.Errorf("invalid symd response: %w", err)
	}
	if (reply.OK && len(reply.Result) == 0) || (!reply.OK && reply.Error == nil) {
		return reply, errors.New("invalid symd response envelope")
	}
	return reply, nil
}
