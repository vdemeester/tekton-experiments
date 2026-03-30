package main

import (
	"fmt"
	"os"

	"github.com/vdemeester/tekton-experiments/pkg/greeting"
)

func main() {
	name := "world"
	if len(os.Args) > 1 {
		name = os.Args[1]
	}
	fmt.Println(greeting.Hello(name))
}
