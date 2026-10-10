setup:
    cd symd && mix deps.get

build: setup
    mkdir -p bin
    cd symd && mix escript.build
    cd cli && go build -buildvcs=false -o ../bin/sym .

test:
    cd symd && mix test --warnings-as-errors
    cd cli && go test ./...

check: test
    cd symd && mix format --check-formatted
    cd cli && sym_unformatted="$(gofmt -l .)" && { test -z "$sym_unformatted" || { printf '%s\n' "$sym_unformatted"; exit 1; }; }
    cd cli && go vet ./...

# Build a local Nix package in result/.
package source=".":
    nix build {{quote(source)}}

test-package:
    cd cli && SYM_TEST_BINARY=../result/bin/sym go test -run TestDaemonLifecycle -count=1
