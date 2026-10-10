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

func TestManagementPreservesAnUnverifiedListener(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "sym-other-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "socket")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	original, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	requests := make(chan request, 3)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			var req request
			_ = json.NewDecoder(conn).Decode(&req)
			requests <- req
			_, _ = conn.Write([]byte("{\"ok\":true,\"result\":{\"service\":\"something-else\",\"protocol\":1,\"state\":\"running\"}}\n"))
			conn.Close()
		}
	}()
	for _, operation := range []string{"start", "status", "stop"} {
		var stdout, stderr bytes.Buffer
		code := run([]string{"--socket", path, "--service", "/does/not/exist", operation}, &stdout, &stderr)
		if code != 1 || !strings.Contains(stderr.String(), "not a compatible symd") {
			t.Fatalf("%s: exit %d: %s", operation, code, &stderr)
		}
		if req := <-requests; req.Op != "status" {
			t.Fatalf("sent %s to an unverified listener", req.Op)
		}
	}
	current, err := os.Lstat(path)
	if err != nil || !os.SameFile(original, current) {
		t.Fatalf("replaced an unverified listener: %v", err)
	}
}
