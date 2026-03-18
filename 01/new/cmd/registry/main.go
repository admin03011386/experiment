package main

import (
	_ "net/http/pprof"

	"github.com/docker2/new/registry"
	_ "github.com/docker2/new/registry/auth/htpasswd"
	_ "github.com/docker2/new/registry/auth/silly"
	_ "github.com/docker2/new/registry/auth/token"
	_ "github.com/docker2/new/registry/proxy"
	_ "github.com/docker2/new/registry/storage/driver/azure"
	_ "github.com/docker2/new/registry/storage/driver/filesystem"
	_ "github.com/docker2/new/registry/storage/driver/gcs"
	_ "github.com/docker2/new/registry/storage/driver/inmemory"
	_ "github.com/docker2/new/registry/storage/driver/middleware/cloudfront"
	_ "github.com/docker2/new/registry/storage/driver/middleware/redirect"
	_ "github.com/docker2/new/registry/storage/driver/oss"
	_ "github.com/docker2/new/registry/storage/driver/s3-aws"
	_ "github.com/docker2/new/registry/storage/driver/s3-goamz"
	_ "github.com/docker2/new/registry/storage/driver/swift"
	// _ "github.com/docker2/new/registry/storage/driver/distributed" // disabled: requires zookeeper CGO
)


func main() {
	registry.RootCmd.Execute()
}
