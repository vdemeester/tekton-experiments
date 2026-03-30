package greeting

import "testing"

func TestHello(t *testing.T) {
	tests := []struct {
		name string
		input string
		want string
	}{
		{"default", "world", "Hello, world!"},
		{"custom", "Tekton", "Hello, Tekton!"},
		{"empty", "", "Hello, !"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Hello(tt.input)
			if got != tt.want {
				t.Errorf("Hello(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestVersion(t *testing.T) {
	v := Version()
	if v == "" {
		t.Error("Version() returned empty string")
	}
}
