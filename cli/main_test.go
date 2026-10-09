package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

// A fake daemon on a Unix socket: the CLI must send exactly {"op","lsp"} and
// print the reply byte-for-byte. The socket lives in /tmp rather than t.TempDir()
// because Unix socket paths are capped at about 100 bytes on macOS.
func TestSocketClientSendsSemanticRequest(t *testing.T) {
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
	defer listener.Close()
	requests := make(chan map[string]string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		var request map[string]string
		if err := json.NewDecoder(conn).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		requests <- request
		conn.Write([]byte("{\"ok\":true,\"result\":{\"lsp\":\"dexter\"}}\n"))
	}()
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--socket", socket, "add", "--lsp", "dexter"}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d: %s", code, &stderr)
	}
	request := <-requests
	if len(request) != 2 || request["op"] != "add" || request["lsp"] != "dexter" {
		t.Fatalf("unexpected request: %#v", request)
	}
	if stdout.String() != "{\"ok\":true,\"result\":{\"lsp\":\"dexter\"}}\n" {
		t.Fatalf("unexpected response: %s", &stdout)
	}
}

// A shell script stands in for symd. It checks the argv it was started with
// (including a config path with spaces) and the request on stdin, then replies
// with an error envelope and exits 1, the way symd does for a failed install.
// The CLI must still print that envelope and exit 1 rather than treating the
// non-zero exit as a transport failure.
func TestOneShotPreservesArgumentsAndErrorReply(t *testing.T) {
	service := filepath.Join(t.TempDir(), "fake symd")
	script := `#!/bin/sh
[ "$1" = "--oneshot" ] && [ "$2" = "--config" ] && [ "$3" = "config with spaces.toml" ] || exit 2
IFS= read -r request
[ "$request" = '{"op":"add","lsp":"dexter"}' ] || exit 3
printf '%s\n' '{"ok":false,"error":{"code":"package_install_failed","message":"test failure"}}'
exit 1
`
	if err := os.WriteFile(service, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--oneshot", "--service", service, "--config", "config with spaces.toml", "add", "--lsp", "dexter"}, &stdout, &stderr)
	if code != 1 {
		t.Fatalf("exit %d: %s", code, &stderr)
	}
	var reply map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &reply); err != nil {
		t.Fatalf("%v; stderr: %s", err, &stderr)
	}
	if reply["ok"] != false || reply["error"].(map[string]any)["code"] != "package_install_failed" {
		t.Fatalf("unexpected response: %s", &stdout)
	}
}

// No socket or service is set up here, so if any of these reached the network
// they'd fail with exit 1 instead of the usage exit 2.
func TestInvalidArgumentsDoNotSendRequests(t *testing.T) {
	for _, args := range [][]string{{}, {"add"}, {"list", "extra"}, {"add", "--lsp", "dexter", "extra"}} {
		var stdout, stderr bytes.Buffer
		if code := run(args, &stdout, &stderr); code != 2 {
			t.Fatalf("%v: exit %d: %s", args, code, &stderr)
		}
	}
}
