package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// request is the one JSON object we send to symd per invocation. Op is "add" or
// "list"; LSP is only filled in for "add" and is left out of the JSON otherwise.
type request struct {
	Op  string `json:"op"`
	LSP string `json:"lsp,omitempty"`
}

// response mirrors symd's reply envelope: either ok=true with a result, or
// ok=false with an error. Result stays raw so we can print it back exactly as
// symd sent it, without knowing its shape.
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

// run is the whole CLI: parse flags and the subcommand, build one request, send
// it (either to the daemon socket or to a fresh symd process), then print the
// reply. Exit codes: 0 success, 1 symd or transport failure, 2 bad usage.
// Nothing is sent when the arguments are wrong.
func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("sym", flag.ContinueOnError)
	flags.SetOutput(stderr)
	socket := flags.String("socket", ".sym/symd.sock", "symd Unix socket")
	oneshot := flags.Bool("oneshot", false, "invoke symd once over stdin/stdout")
	config := flags.String("config", "sym.toml", "TOML file for one-shot mode")
	service := flags.String("service", siblingService(), "symd executable for one-shot mode")
	flags.Usage = func() {
		fmt.Fprintln(stderr, "Usage: sym [options] add --lsp NAME | list")
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
	// Global flags stop at the first non-flag word, so everything after it is the
	// subcommand and its own arguments. "add" gets its own flag set for --lsp.
	command := flags.Args()
	var req request
	switch command[0] {
	case "add":
		add := flag.NewFlagSet("add", flag.ContinueOnError)
		add.SetOutput(stderr)
		lsp := add.String("lsp", "", "language server name")
		if err := add.Parse(command[1:]); err != nil {
			return 2
		}
		if *lsp == "" || add.NArg() != 0 {
			fmt.Fprintln(stderr, "Usage: sym [options] add --lsp NAME")
			return 2
		}
		req = request{Op: "add", LSP: *lsp}
	case "list":
		if len(command) != 1 {
			fmt.Fprintln(stderr, "Usage: sym [options] list")
			return 2
		}
		req = request{Op: "list"}
	default:
		flags.Usage()
		return 2
	}

	// Two ways to reach symd: the long-running daemon over its Unix socket, or a
	// one-off symd process that reads the request on stdin. Both return the same
	// response shape, so the printing below doesn't care which one ran.
	var reply response
	var err error
	if *oneshot {
		reply, err = oneShotRequest(*service, *config, req, stderr)
	} else {
		reply, err = socketRequest(*socket, req)
	}
	if err != nil {
		fmt.Fprintf(stderr, "sym: %v\n", err)
		return 1
	}
	if err := json.NewEncoder(stdout).Encode(reply); err != nil {
		fmt.Fprintf(stderr, "sym: %v\n", err)
		return 1
	}
	if !reply.OK {
		return 1
	}
	return 0
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

// oneShotRequest runs symd once, writes the request to its stdin, and reads the
// reply from stdout. The tricky part is exit codes: symd exits non-zero for
// failures like a failed package install, but it still prints a proper error
// envelope. So we only call it a transport failure when there's no output at
// all. If there is output, we return the reply and let run print it.
func oneShotRequest(service, config string, req request, stderr io.Writer) (response, error) {
	var input bytes.Buffer
	if err := json.NewEncoder(&input).Encode(req); err != nil {
		return response{}, err
	}
	command := exec.Command(service, "--oneshot", "--config", config)
	command.Stdin = &input
	command.Stderr = stderr
	output, commandErr := command.Output()
	if commandErr != nil && len(output) == 0 {
		return response{}, fmt.Errorf("symd: %w", commandErr)
	}
	reply, err := decodeResponse(bytes.NewReader(output))
	if err != nil {
		return reply, err
	}
	if commandErr != nil && reply.OK {
		return reply, fmt.Errorf("symd: %w", commandErr)
	}
	return reply, nil
}

// socketRequest sends one request line to the daemon and reads one reply line.
// The connection is closed when we're done, so every call is its own round trip.
// Only the dial has a timeout (3s); reading the reply has no deadline, so a hung
// daemon would block here.
func socketRequest(path string, req request) (response, error) {
	conn, err := net.DialTimeout("unix", path, 3*time.Second)
	if err != nil {
		return response{}, err
	}
	defer conn.Close()
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return response{}, err
	}
	return decodeResponse(conn)
}

// decodeResponse parses symd's reply and checks that it's a valid envelope. The
// reader is capped at 1 MiB so a runaway process can't make us read forever. We
// also reject replies that claim ok but have no result, or claim failure but
// have no error, because those can't be printed or explained to the user.
func decodeResponse(reader io.Reader) (response, error) {
	var reply response
	if err := json.NewDecoder(io.LimitReader(reader, 1024*1024)).Decode(&reply); err != nil {
		return reply, fmt.Errorf("invalid symd response: %w", err)
	}
	if (reply.OK && len(reply.Result) == 0) || (!reply.OK && reply.Error == nil) {
		return reply, errors.New("invalid symd response envelope")
	}
	return reply, nil
}
