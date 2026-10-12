package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// symbolInfo and location mirror the shapes inside symd's semantic results.
// Everything optional stays a zero value, so one decode covers def results
// with and without name information.
type symbolInfo struct {
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Container string `json:"container"`
	Path      string `json:"path"`
	Line      int    `json:"line"`
	Column    int    `json:"column"`
}

type location struct {
	Path   string `json:"path"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
	Text   string `json:"text"`
}

type semanticResult struct {
	Symbols     []symbolInfo `json:"symbols"`
	Definitions []symbolInfo `json:"definitions"`
	Matches     []struct {
		Symbol *symbolInfo `json:"symbol"`
		Refs   []location  `json:"refs"`
	} `json:"matches"`
	Candidates []symbolInfo `json:"candidates"`
}

// printSemantic formats a semantic reply. The default output is one
// path:line:column per line — the shape every tool already parses — with
// symbol descriptions after a tab where they exist. Grouping only appears
// when a name matched several symbols. Exit codes: 0 answered, 1 failed,
// 3 too ambiguous to answer (candidates were printed instead).
// With source set, each reference line also carries its source line after a
// tab, so a reader can tell an import from a call without opening the file.
func printSemantic(req request, reply response, asJSON, source bool, stdout, stderr io.Writer) int {
	if !reply.OK {
		fmt.Fprintf(stderr, "sym: %s: %s\n", reply.Error.Code, reply.Error.Message)
		return 1
	}
	var result semanticResult
	if err := json.Unmarshal(reply.Result, &result); err != nil {
		fmt.Fprintf(stderr, "sym: invalid symd result: %v\n", err)
		return 1
	}
	ambiguous := len(result.Candidates) > 0
	if ambiguous {
		fmt.Fprintf(stderr, "sym: %q matches %d symbols; narrow with a qualified name or --at FILE:LINE:COL\n",
			req.Name, len(result.Candidates))
	}
	if asJSON {
		fmt.Fprintf(stdout, "%s\n", reply.Result)
	} else {
		printLines(req, result, source, stdout)
	}
	if ambiguous {
		return 3
	}
	return 0
}

func printLines(req request, result semanticResult, source bool, stdout io.Writer) {
	base, _ := os.Getwd()
	switch {
	case len(result.Candidates) > 0:
		for _, symbol := range result.Candidates {
			fmt.Fprintln(stdout, describe(base, symbol))
		}
	case req.Op == "symbols":
		for _, symbol := range result.Symbols {
			fmt.Fprintln(stdout, describe(base, symbol))
		}
	case req.Op == "def":
		for _, symbol := range result.Definitions {
			fmt.Fprintln(stdout, describe(base, symbol))
		}
	case len(result.Matches) == 1:
		for _, ref := range result.Matches[0].Refs {
			fmt.Fprintln(stdout, reference(base, ref, source))
		}
	default:
		for index, match := range result.Matches {
			if index > 0 {
				fmt.Fprintln(stdout)
			}
			if match.Symbol != nil {
				fmt.Fprintf(stdout, "%s (%s) %s\n", qualified(*match.Symbol), match.Symbol.Kind,
					place(base, match.Symbol.Path, match.Symbol.Line, match.Symbol.Column))
			}
			for _, ref := range match.Refs {
				fmt.Fprintf(stdout, "  %s\n", reference(base, ref, source))
			}
		}
	}
}

// describe is a location line, plus the symbol description when there is one:
// definitions found through a position have a place but no name.
func describe(base string, symbol symbolInfo) string {
	where := place(base, symbol.Path, symbol.Line, symbol.Column)
	if symbol.Name == "" {
		return where
	}
	return fmt.Sprintf("%s\t%s (%s)", where, qualified(symbol), symbol.Kind)
}

func reference(base string, ref location, source bool) string {
	where := place(base, ref.Path, ref.Line, ref.Column)
	if !source {
		return where
	}
	return where + "\t" + ref.Text
}

func qualified(symbol symbolInfo) string {
	if symbol.Container == "" {
		return symbol.Name
	}
	return symbol.Container + "." + symbol.Name
}

func place(base, path string, line, column int) string {
	return fmt.Sprintf("%s:%d:%d", displayPath(base, path), line, column)
}

// displayPath keeps machine output stable (the wire carries absolute paths)
// while humans see paths relative to where they ran sym, when that's shorter
// than pointing somewhere outside it.
func displayPath(base, path string) string {
	if base == "" {
		return path
	}
	relative, err := filepath.Rel(base, path)
	if err != nil || strings.HasPrefix(relative, "..") {
		return path
	}
	return relative
}
