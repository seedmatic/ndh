// ndh-nix-signing-derive derives a builder's nix signing key from its ssh host key (roles × keys B2).
//
// It reads an unencrypted OpenSSH ed25519 private key on stdin, and prints the nix key derived from its seed by
// HKDF-SHA256 (salt "seedmatic", info = the label): either its public, `<name>:<base64 pk>`, or its secret in
// nix's format, `<name>:<base64 seed‖pk>`, never both. The derived key is a distinct key, so no key signs both
// ssh and narinfo. Nothing here knows keys.yaml: the caller records the public, and checks it.
//
//	ndh-nix-signing-derive --name seedmatic-<machine>-<n> --label seedmatic/nix-signing/<n> --public|--secret
//
// Errors name the failure, never the bytes read.
package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"

	"golang.org/x/crypto/hkdf"
	"golang.org/x/crypto/ssh"
)

const (
	salt     = "seedmatic"
	maxInput = 16 << 10
)

var (
	// A key name and a label, as the catalog writes them: lowercase words, no base64 alphabet beyond that, so an
	// argument that looks like key material (uppercase, '+', '=', ':') is refused.
	namePattern  = regexp.MustCompile(`^[a-z][a-z0-9.-]*-[0-9]+$`)
	labelPattern = regexp.MustCompile(`^[a-z][a-z0-9-]*(/[a-z0-9-]+)+$`)
)

type request struct {
	name, label string
	secret      bool
}

func parseArgs(args []string) (request, error) {
	var r request
	var public bool
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--public":
			public = true
		case "--secret":
			r.secret = true
		case "--name", "--label":
			if i+1 >= len(args) {
				return r, fmt.Errorf("%s needs a value", args[i])
			}
			if args[i] == "--name" {
				r.name = args[i+1]
			} else {
				r.label = args[i+1]
			}
			i++
		default:
			return r, errors.New("unknown argument (only --name, --label, --public, --secret)")
		}
	}
	switch {
	case public == r.secret:
		return r, errors.New("exactly one of --public and --secret")
	case !namePattern.MatchString(r.name):
		return r, errors.New("--name must look like seedmatic-<machine>-<n>")
	case !labelPattern.MatchString(r.label):
		return r, errors.New("--label must look like seedmatic/nix-signing/<n>")
	}
	return r, nil
}

// derive returns the line to print for the host key read from in.
func derive(in io.Reader, r request) (string, error) {
	data, err := io.ReadAll(io.LimitReader(in, maxInput+1))
	if err != nil {
		return "", errors.New("cannot read stdin")
	}
	defer clear(data)
	if len(data) > maxInput {
		return "", errors.New("stdin is larger than any OpenSSH private key")
	}
	raw, err := ssh.ParseRawPrivateKey(data)
	if err != nil {
		var missing *ssh.PassphraseMissingError
		if errors.As(err, &missing) {
			return "", errors.New("the host key is passphrase-protected; refused")
		}
		return "", errors.New("stdin is not an OpenSSH private key")
	}
	host, ok := raw.(*ed25519.PrivateKey)
	if !ok {
		return "", errors.New("the host key is not ed25519; refused")
	}
	defer clear(*host)

	seed := make([]byte, ed25519.SeedSize)
	defer clear(seed)
	if _, err := io.ReadFull(hkdf.New(sha256.New, host.Seed(), []byte(salt), []byte(r.label)), seed); err != nil {
		return "", errors.New("the derivation failed")
	}
	derived := ed25519.NewKeyFromSeed(seed)
	defer clear(derived)
	public := derived.Public().(ed25519.PublicKey)
	if string(public) == string(host.Public().(ed25519.PublicKey)) {
		return "", errors.New("the derived key equals the host key; refused")
	}
	if r.secret {
		return r.name + ":" + base64.StdEncoding.EncodeToString(derived), nil
	}
	return r.name + ":" + base64.StdEncoding.EncodeToString(public), nil
}

func main() {
	r, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "ndh-nix-signing-derive:", err)
		os.Exit(64)
	}
	line, err := derive(os.Stdin, r)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ndh-nix-signing-derive:", err)
		os.Exit(65)
	}
	fmt.Println(line)
}
