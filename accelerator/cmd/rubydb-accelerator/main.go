package main

import (
	"os"

	acceleratorRuntime "github.com/aldanedev-create/rubydb/accelerator/internal/runtime"
)

func main() {
	acceleratorRuntime.Run(os.Stdin, os.Stdout)
}
