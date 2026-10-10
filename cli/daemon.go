package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// protocol is the CLI/daemon wire version. Both halves ship together; the
// check catches a daemon left running across a package upgrade.
const protocol = 3

// The CLI only launches its companion and talks to its management protocol.
// There is no PID file to trust, and stop never signals an arbitrary process.
func stoppedReply() response {
	return response{OK: true, Result: json.RawMessage(
		fmt.Sprintf(`{"service":"symd","protocol":%d,"state":"stopped"}`, protocol))}
}

func daemonStatus(socket string, timeout time.Duration) (response, error) {
	reply, err := socketRequestWithin(socket, request{Op: "status"}, timeout)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED) {
		return stoppedReply(), nil
	}
	if err != nil {
		return response{}, fmt.Errorf("cannot verify symd at %s: %w", socket, err)
	}
	var status struct {
		Service  string
		Protocol int
		State    string
		PID      string
	}
	if err := json.Unmarshal(reply.Result, &status); err != nil || !reply.OK ||
		status.Service != "symd" || status.Protocol != protocol || status.State != "running" {
		return response{}, fmt.Errorf("%s is not a compatible symd listener", socket)
	}
	if pid, err := strconv.Atoi(status.PID); err != nil || pid <= 0 {
		return response{}, fmt.Errorf("%s did not identify its symd process", socket)
	}
	return reply, nil
}

func isRunning(reply response) bool {
	var status struct{ State string }
	return json.Unmarshal(reply.Result, &status) == nil && status.State == "running"
}

func startDaemon(service, socket string) (response, error) {
	reply, err := daemonStatus(socket, time.Second)
	if err != nil || isRunning(reply) {
		return reply, err
	}
	// Resolve a caller-relative path before the child outlives this invocation.
	socket, err = filepath.Abs(socket)
	if err != nil {
		return response{}, err
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0700); err != nil {
		return response{}, err
	}
	logPath := socket + ".log"
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return response{}, err
	}
	defer log.Close()
	command := exec.Command(service, "--socket", socket)
	command.Stdin = nil // os/exec supplies /dev/null.
	command.Stdout, command.Stderr = log, log
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		return response{}, fmt.Errorf("cannot start symd: %w", err)
	}
	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-tick.C:
			if reply, err := daemonStatus(socket, time.Second); err == nil && isRunning(reply) {
				var status struct{ PID string }
				_ = json.Unmarshal(reply.Result, &status)
				if status.PID != strconv.Itoa(command.Process.Pid) {
					// Another start won. Reap our candidate before returning so it
					// can't bind later, after the winning daemon has been stopped.
					_ = command.Process.Kill()
					<-exited
				}
				return reply, nil
			}
		case err := <-exited:
			// A competing start may have won the bind. That's still a successful
			// start for the caller, provided we verify the listener's identity.
			if reply, probeErr := daemonStatus(socket, time.Second); probeErr == nil && isRunning(reply) {
				return reply, nil
			}
			return response{}, startupError(logPath, err)
		case <-deadline.C:
			// This handle belongs to the child we just started, never a PID read
			// from a file or returned by some pre-existing socket listener.
			_ = command.Process.Kill()
			<-exited
			return response{}, startupError(logPath, errors.New("startup timed out"))
		}
	}
}

func startupError(logPath string, reason error) error {
	log, _ := os.ReadFile(logPath)
	if len(log) > 8192 {
		log = log[len(log)-8192:]
	}
	return fmt.Errorf("symd did not start (%v); log: %s\n%s", reason, logPath, log)
}

// semanticRequest reaches the daemon, starting one when none is running. A
// daemon that rejects a well-formed request as invalid may be a pre-upgrade
// version; when its status confirms symd on another protocol, it is stopped
// and replaced, so a nix upgrade doesn't need a manual sym stop.
func semanticRequest(service, socket string, req request) (response, error) {
	reply, err := socketRequestWithin(socket, req, 0)
	switch {
	case errors.Is(err, os.ErrNotExist), errors.Is(err, syscall.ECONNREFUSED):
		// Not running: fall through to the start below.
	case err == nil && !reply.OK && reply.Error != nil && reply.Error.Code == "invalid_request" &&
		replaceStale(socket):
		// Replaced a stale daemon: fall through to the start below.
	default:
		return reply, err
	}
	if _, err := startDaemon(service, socket); err != nil {
		return response{}, err
	}
	return socketRequestWithin(socket, req, 0)
}

// replaceStale stops a listener that identifies itself as a running symd on a
// different protocol version, and reports whether that happened. Anything
// else — another service, a current symd whose rejection was real — is left
// alone.
func replaceStale(socket string) bool {
	reply, err := socketRequestWithin(socket, request{Op: "status"}, time.Second)
	if err != nil || !reply.OK {
		return false
	}
	var status struct {
		Service  string
		Protocol int
		State    string
	}
	if json.Unmarshal(reply.Result, &status) != nil ||
		status.Service != "symd" || status.State != "running" || status.Protocol == protocol {
		return false
	}
	ownedSocket, err := os.Lstat(socket)
	if err != nil {
		return false
	}
	if reply, err := socketRequestWithin(socket, request{Op: "stop"}, time.Second); err != nil || !reply.OK {
		return false
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		current, err := os.Lstat(socket)
		if errors.Is(err, os.ErrNotExist) || (err == nil && !os.SameFile(ownedSocket, current)) {
			return true
		}
		if err != nil {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func stopDaemon(socket string) (response, error) {
	// A graceful stop waits behind an in-flight installation. The status
	// handshake also prevents sending management commands to an unknown service.
	reply, err := daemonStatus(socket, 0)
	if err != nil || !isRunning(reply) {
		return reply, err
	}
	ownedSocket, err := os.Lstat(socket)
	if err != nil {
		return response{}, err
	}
	reply, err = socketRequest(socket, request{Op: "stop"})
	if err != nil || !reply.OK {
		return reply, err
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		current, err := os.Lstat(socket)
		if errors.Is(err, os.ErrNotExist) || (err == nil && !os.SameFile(ownedSocket, current)) {
			return stoppedReply(), nil
		}
		if err != nil {
			return response{}, err
		}
		time.Sleep(20 * time.Millisecond)
	}
	return response{}, errors.New("symd acknowledged stop but has not removed its socket yet")
}
