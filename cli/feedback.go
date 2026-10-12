package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// feedback keeps a plain list of wishes and problems, written by whoever uses
// sym (agents mostly) at the moment the tool let them down, so improving it
// starts from real friction. With text it appends one line; without, it
// prints every line so far.
func feedback(args []string, stdout, stderr io.Writer) int {
	path, err := feedbackPath()
	if err != nil {
		fmt.Fprintf(stderr, "sym: %v\n", err)
		return 1
	}
	if len(args) == 0 {
		content, err := os.ReadFile(path)
		if errors.Is(err, fs.ErrNotExist) {
			return 0
		}
		if err != nil {
			fmt.Fprintf(stderr, "sym: %v\n", err)
			return 1
		}
		stdout.Write(content)
		return 0
	}
	// One note is one line, whatever the shell passed in.
	note := strings.Join(strings.Fields(strings.Join(args, " ")), " ")
	if note == "" {
		fmt.Fprintln(stderr, "Usage: sym --feedback \"TEXT\" | sym --feedback")
		return 2
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		fmt.Fprintf(stderr, "sym: %v\n", err)
		return 1
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(stderr, "sym: %v\n", err)
		return 1
	}
	defer file.Close()
	if _, err := fmt.Fprintln(file, note); err != nil {
		fmt.Fprintf(stderr, "sym: %v\n", err)
		return 1
	}
	return 0
}

// feedbackPath sits next to the daemon socket in ~/.sym, sym's one home.
func feedbackPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".sym", "feedback.txt"), nil
}
