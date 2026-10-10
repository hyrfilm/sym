package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// This runs the installed package, not an in-process imitation of symd. Keeping
// the caller's PATH bare catches wrappers that accidentally rely on nix develop.
func TestDaemonLifecycle(t *testing.T) {
	binary := os.Getenv("SYM_TEST_BINARY")
	if binary == "" {
		t.Skip("set SYM_TEST_BINARY to test an installed package")
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}
	// The directory name keeps a space so path handling stays honest.
	dir, err := os.MkdirTemp("/tmp", "sym release ")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	project := filepath.Join(dir, "project")
	nested := filepath.Join(project, "deeply", "nested")
	if err := os.MkdirAll(nested, 0700); err != nil {
		t.Fatal(err)
	}
	toml := "[lsp.absent]\ncommand = 'definitely-not-installed-lsp'\nextensions = ['.zz']\n"
	if err := os.WriteFile(filepath.Join(project, "sym.toml"), []byte(toml), 0600); err != nil {
		t.Fatal(err)
	}
	// No sym.toml and no .git anywhere above it.
	outside := filepath.Join(dir, "outside")
	if err := os.MkdirAll(outside, 0700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "run", "symd.sock")
	t.Setenv("PATH", "/usr/bin:/bin")
	// Keep the daemon's global-config lookup away from the developer's real one.
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "xdg"))
	invoke := func(cwd string, args ...string) (response, string, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, binary, append([]string{"--socket", socket}, args...)...)
		command.Dir = cwd
		var stdout, stderr bytes.Buffer
		command.Stdout, command.Stderr = &stdout, &stderr
		err := command.Run()
		var reply response
		if decodeErr := json.Unmarshal(stdout.Bytes(), &reply); err == nil && decodeErr != nil {
			err = decodeErr
		}
		return reply, stderr.String(), err
	}
	// Stop only our uniquely addressed daemon, even when an assertion fails.
	t.Cleanup(func() { _, _, _ = invoke(project, "stop") })
	state := func(command, expected string) string {
		t.Helper()
		reply, stderr, err := invoke(project, command)
		if err != nil {
			t.Fatalf("%s: %v: %s", command, err, stderr)
		}
		var result struct{ Service, State, PID string }
		if err := json.Unmarshal(reply.Result, &result); err != nil {
			t.Fatal(err)
		}
		if !reply.OK || result.Service != "symd" || result.State != expected {
			t.Fatalf("%s: unexpected reply %+v", command, reply)
		}
		return result.PID
	}
	state("status", "stopped")
	state("stop", "stopped")
	pid := state("start", "running")
	if again := state("start", "running"); again != pid {
		t.Fatal("repeated start replaced the running daemon")
	}
	state("status", "running")
	// Queries carry their cwd: from a nested directory the daemon resolves
	// the project root above it. An extension nothing is configured for is
	// refused, and a name query that needs the configured server reports the
	// missing executable instead of hanging or crashing.
	if _, stderr, err := invoke(nested, "symbols", filepath.Join(project, "readme.txt")); err == nil ||
		!strings.Contains(stderr, "unsupported_file") {
		t.Fatalf("expected an unsupported_file refusal: %v: %s", err, stderr)
	}
	if _, stderr, err := invoke(nested, "refs", "anything"); err == nil ||
		!strings.Contains(stderr, "lsp_unavailable") {
		t.Fatalf("expected an lsp_unavailable failure: %v: %s", err, stderr)
	}
	// Outside any workspace there is nothing to resolve against.
	if _, stderr, err := invoke(outside, "refs", "anything"); err == nil ||
		!strings.Contains(stderr, "no_workspace") {
		t.Fatalf("expected a no_workspace failure: %v: %s", err, stderr)
	}
	state("stop", "stopped")
	if _, err := os.Lstat(socket); !os.IsNotExist(err) {
		t.Fatalf("stop left the socket behind: %v", err)
	}

	// With no daemon running, a query auto-starts one and still answers.
	if _, stderr, err := invoke(nested, "refs", "anything"); err == nil ||
		!strings.Contains(stderr, "lsp_unavailable") {
		t.Fatalf("expected auto-start and an lsp_unavailable failure: %v: %s", err, stderr)
	}
	state("status", "running")
	state("stop", "stopped")

	// A crash leaves the file but releases the listener. The next start should
	// recover it without requiring a manual rm or a stale PID file.
	ownedPID, err := strconv.Atoi(state("start", "running"))
	if err != nil {
		t.Fatal(err)
	}
	ownedProcess, err := os.FindProcess(ownedPID)
	if err != nil {
		t.Fatal(err)
	}
	if err := ownedProcess.Kill(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		reply, _, err := invoke(project, "status")
		if err == nil && !isRunning(reply) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("test daemon did not terminate")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Lstat(socket); err != nil {
		t.Fatalf("test did not leave a stale socket: %v", err)
	}
	state("start", "running")
	state("stop", "stopped")

	// Concurrent starts must converge on one verified instance. Neither losing
	// launcher may leave a candidate around to appear after a later stop.
	type startResult struct {
		reply  response
		stderr string
		err    error
	}
	starts := make(chan startResult, 2)
	for range 2 {
		go func() {
			reply, stderr, err := invoke(project, "start")
			starts <- startResult{reply, stderr, err}
		}()
	}
	var winner string
	for range 2 {
		result := <-starts
		if result.err != nil {
			t.Fatalf("concurrent start: %v: %s", result.err, result.stderr)
		}
		var status struct{ PID string }
		if err := json.Unmarshal(result.reply.Result, &status); err != nil || status.PID == "" {
			t.Fatalf("invalid concurrent start reply: %s", result.reply.Result)
		}
		if winner != "" && winner != status.PID {
			t.Fatal("concurrent starts produced different daemons")
		}
		winner = status.PID
	}
	state("stop", "stopped")
}
