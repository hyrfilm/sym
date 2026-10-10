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

// The CLI only launches its companion and talks to its management protocol.
// There is no PID file to trust, and stop never signals an arbitrary process.
func stoppedReply() response {
	return response{OK: true, Result: json.RawMessage(`{"service":"symd","protocol":2,"state":"stopped"}`)}
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
		status.Service != "symd" || status.Protocol != 2 || status.State != "running" {
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

func startDaemon(service, config, socket string) (response, error) {
	reply, err := daemonStatus(socket, time.Second)
	if err != nil || isRunning(reply) {
		return reply, err
	}
	// Resolve caller-relative paths before the child outlives this invocation.
	config, err = filepath.Abs(config)
	if err != nil {
		return response{}, err
	}
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
	command := exec.Command(service, "--config", config, "--socket", socket)
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
