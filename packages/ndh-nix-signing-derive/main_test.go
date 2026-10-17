package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/pem"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

const (
	name  = "seedmatic-bioskop-1"
	label = "seedmatic/nix-signing/1"
)

// hostKey is a fixed host key, so the derived key is a known vector, cross-checked once with openssl
// (kdf HKDF on the seed, then pkey on the derived seed).
func hostKey(t *testing.T) (ed25519.PrivateKey, []byte) {
	t.Helper()
	priv := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x01}, ed25519.SeedSize))
	block, err := ssh.MarshalPrivateKey(priv, "")
	if err != nil {
		t.Fatal(err)
	}
	return priv, pem.EncodeToMemory(block)
}

func run(t *testing.T, in []byte, r request) (string, error) {
	t.Helper()
	return derive(bytes.NewReader(in), r)
}

func TestKnownVector(t *testing.T) {
	_, in := hostKey(t)
	got, err := run(t, in, request{name: name, label: label})
	if err != nil {
		t.Fatal(err)
	}
	const want = "seedmatic-bioskop-1:pwlhKhsPh24o6edPjMUxJSmFbyufAOYADHBe0Jfy0P0="
	if got != want {
		t.Fatalf("derived public = %s, want %s", got, want)
	}
}

func TestStableAndLabelSeparated(t *testing.T) {
	_, in := hostKey(t)
	a, _ := run(t, in, request{name: name, label: label})
	b, _ := run(t, in, request{name: name, label: label})
	c, _ := run(t, in, request{name: name, label: "seedmatic/nix-signing/2"})
	if a != b {
		t.Fatal("the same host key and label gave two keys")
	}
	if a == c {
		t.Fatal("another label gave the same key")
	}
}

func TestSecretCarriesThePublic(t *testing.T) {
	_, in := hostKey(t)
	pub, _ := run(t, in, request{name: name, label: label})
	sec, err := run(t, in, request{name: name, label: label, secret: true})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(sec, name+":"))
	if err != nil || len(raw) != ed25519.PrivateKeySize {
		t.Fatalf("the secret is not nix's 64-byte ed25519 key: %d bytes, %v", len(raw), err)
	}
	fromSecret := name + ":" + base64.StdEncoding.EncodeToString(ed25519.PrivateKey(raw).Public().(ed25519.PublicKey))
	if fromSecret != pub {
		t.Fatal("the secret's public differs from --public")
	}
}

func TestDiffersFromTheHostKey(t *testing.T) {
	priv, in := hostKey(t)
	pub, _ := run(t, in, request{name: name, label: label})
	host := base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
	if strings.TrimPrefix(pub, name+":") == host {
		t.Fatal("the derived public is the host public")
	}
}

func TestRefusals(t *testing.T) {
	priv, _ := hostKey(t)
	locked, err := ssh.MarshalPrivateKeyWithPassphrase(priv, "", []byte("passphrase"))
	if err != nil {
		t.Fatal(err)
	}
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	rsaBlock, err := ssh.MarshalPrivateKey(rsaKey, "")
	if err != nil {
		t.Fatal(err)
	}
	secretInput := []byte("-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-key-SECRET-BYTES\n-----END OPENSSH PRIVATE KEY-----\n")
	for what, in := range map[string][]byte{
		"passphrase-protected": pem.EncodeToMemory(locked),
		"rsa":                  pem.EncodeToMemory(rsaBlock),
		"garbage":              secretInput,
		"empty":                nil,
		"oversized":            bytes.Repeat([]byte("A"), maxInput+1),
	} {
		_, err := run(t, in, request{name: name, label: label})
		if err == nil {
			t.Errorf("%s: accepted", what)
			continue
		}
		if strings.Contains(err.Error(), "SECRET-BYTES") {
			t.Errorf("%s: the error echoes its input: %v", what, err)
		}
	}
}

func TestArguments(t *testing.T) {
	ok := []string{"--name", name, "--label", label, "--public"}
	if _, err := parseArgs(ok); err != nil {
		t.Fatalf("refused %v: %v", ok, err)
	}
	for _, args := range [][]string{
		{"--name", name, "--label", label},
		{"--name", name, "--label", label, "--public", "--secret"},
		{"--name", "AAAAC3NzaC1lZDI1NTE5AAAAI", "--label", label, "--public"},
		{"--name", name + ":x", "--label", label, "--public"},
		{"--name", name, "--label", "Seedmatic/Nix+signing=", "--public"},
		{"--name", name, "--label", label, "--public", "extra"},
		{"--name"},
	} {
		if _, err := parseArgs(args); err == nil {
			t.Errorf("accepted %v", args)
		}
	}
}
