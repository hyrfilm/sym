build:
    mkdir -p bin
    cd symd && mix escript.build
    cd cli && go build -buildvcs=false -o ../bin/sym .

test:
    cd symd && mix test --warnings-as-errors
    cd cli && go test ./...
