# A fresh ed25519 key in OpenSSH format, generated in memory: the private on stdout (piped into
# `pass insert -m`, never a file: ssh-keygen writes only files and macOS has no tmpfs), its public on
# file descriptor 3. The bytes come from OpenSSL's RAND_bytes, seeded by the OS.
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

key = Ed25519PrivateKey.generate()
sys.stdout.write(
    key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.OpenSSH,
        serialization.NoEncryption(),
    ).decode()
)
sys.stdout.flush()
public = key.public_key().public_bytes(
    serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH
)
os.write(3, public + b"\n")
