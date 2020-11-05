// This package is the entrypoint for the Firmware Transparency personality server.
// This requires a Trillian instance to be reachable via gRPC and a tree to have
// been provisioned. See the README in the root of this project for instructions.
// Start the server using:
// go run ./cmd/ft_personality/main.go --logtostderr -v=2 --tree_id=$TREE_ID
package main

import (
	"context"
	"flag"
	"net/http"
	"time"

	"github.com/golang/glog"
	ih "github.com/google/trillian-examples/binary_transparency/firmware/cmd/ft_personality/internal/http"
	"github.com/google/trillian-examples/binary_transparency/firmware/cmd/ft_personality/internal/trillian"

	_ "github.com/google/trillian/merkle/rfc6962" // Load hashers
)

var (
	listenAddr = flag.String("listen", ":8000", "address:port to listen for requests on")

	connectTimeout = flag.Duration("connect_timeout", time.Second, "the timeout for connecting to the backend")
	trillianAddr   = flag.String("trillian", ":8090", "address:port of Trillian Log gRPC service")
	treeID         = flag.Int64("tree_id", -1, "the tree ID of the log to use")
)

func main() {
	flag.Parse()

	if *treeID < 0 {
		glog.Exitf("tree_id is required")
	}
	glog.Infof("Connecting to Trillian Log...")
	tclient, err := trillian.NewClient(context.Background(), *connectTimeout, *trillianAddr, *treeID)
	if err != nil {
		glog.Exitf("failed to connect to Trillian: %v", err)
	}
	defer tclient.Close()

	glog.Infof("Starting FT personality server...")
	srv := ih.NewServer(tclient)

	srv.RegisterHandlers()

	glog.Fatal(http.ListenAndServe(*listenAddr, nil))
}
