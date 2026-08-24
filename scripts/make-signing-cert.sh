#!/usr/bin/env bash
#
# Create a local self-signed certificate for signing Transcriber.app.
#
# Why: macOS binds granted permissions (microphone, system audio capture) to the app's
# signature. With ad-hoc signing every rebuild changes the cdhash, the system treats the
# app as new, and it quietly stops granting access to audio — the recording comes out
# silent with nothing in the log. A stable certificate removes that whole class of bugs.
#
# Run once. Requires the keychain password.
#
set -euo pipefail

CERT_NAME="Transcriber Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
DAYS=3650
# The PKCS#12 container is a temporary transport format, deleted at the end of this
# script, so the password only has to be non-empty.
P12_PASSWORD="transcriber-import"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
	echo "certificate '${CERT_NAME}' already exists — nothing to do"
	security find-identity -v -p codesigning | grep "$CERT_NAME"
	exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> generating key and certificate"
# extendedKeyUsage=codeSigning is required; without it codesign rejects the identity.
openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "${WORK_DIR}/key.pem" \
	-out "${WORK_DIR}/cert.pem" \
	-days "$DAYS" \
	-subj "/CN=${CERT_NAME}/O=Transcriber" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" \
	2>/dev/null

# OpenSSL 3 defaults to PBES2/AES-256 with a SHA-256 MAC, which macOS `security import`
# rejects with "MAC verification failed". These flags pin the older algorithms the
# Security framework accepts. Homebrew's openssl usually shadows the system LibreSSL,
# so do not rely on whichever one is first in PATH.
openssl pkcs12 -export \
	-out "${WORK_DIR}/cert.p12" \
	-inkey "${WORK_DIR}/key.pem" \
	-in "${WORK_DIR}/cert.pem" \
	-certpbe PBE-SHA1-3DES \
	-keypbe PBE-SHA1-3DES \
	-macalg sha1 \
	-passout "pass:${P12_PASSWORD}"

echo "==> importing into the keychain (may prompt for a password)"
# -T /usr/bin/codesign lets codesign use the key without prompting on every build.
security import "${WORK_DIR}/cert.p12" \
	-k "$KEYCHAIN" \
	-P "$P12_PASSWORD" \
	-T /usr/bin/codesign \
	-T /usr/bin/security

echo "==> trusting it for code signing (may prompt for a password)"
security add-trusted-cert \
	-r trustRoot \
	-p codeSign \
	-k "$KEYCHAIN" \
	"${WORK_DIR}/cert.pem"

# Belt and braces against a "codesign wants to access the key" dialog. This usually fails
# because it would need the login keychain password, which is fine: the -T flags above
# already grant codesign access to the key. If a dialog does appear on the first build,
# choose "Always Allow" once.
security set-key-partition-list \
	-S apple-tool:,apple:,codesign: \
	-s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
	echo "note: skipped the partition list step; if a dialog appears on first build, choose Always Allow"

echo "==> verifying"
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
	security find-identity -v -p codesigning | grep "$CERT_NAME"
	echo "done: project.yml already sets CODE_SIGN_IDENTITY to ${CERT_NAME}"
else
	echo "certificate created but codesign cannot see it — check trust in Keychain Access" >&2
	exit 1
fi
