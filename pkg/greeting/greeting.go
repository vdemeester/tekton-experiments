package greeting

import "fmt"

// Hello returns a greeting for the given name.
func Hello(name string) string {
	return fmt.Sprintf("Hello, %s!", name)
}

// Version returns the build version.
func Version() string {
	return "dev"
}
