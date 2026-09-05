#!/bin/zsh
# Loads the secrets the release workflow needs into the repo.
#
#   ./scripts/setup-ci-secrets.sh              both sections
#   ./scripts/setup-ci-secrets.sh --cert       just the signing certificate
#   ./scripts/setup-ci-secrets.sh --notary     just the notary API key
#   ./scripts/setup-ci-secrets.sh owner/repo   somewhere other than wes/mind
#
# Everything is read locally and piped straight to `gh secret set`, so no
# secret is ever echoed, logged, or pasted into a chat window.
#
# Every value is checked before it is stored: the certificate is opened with
# the password you type and inspected, and the API key is used to make a real
# call to Apple. A wrong file or a mistyped password otherwise surfaces as a
# base64 or "MAC verification failed" error inside a CI runner, minutes and six
# steps away from the thing that actually went wrong.
#
# Safe to re-run. Each section overwrites only its own secrets.
set -euo pipefail

SECTION="all"
case "${1:-}" in
	--cert|--notary) SECTION="${1#--}"; shift ;;
	# Print the comment block above, stopping at the first line that is not a
	# comment, so this stays correct as the header grows.
	# `\?` is a GNU extension that BSD sed ignores without complaint, hence
	# two plain substitutions rather than one clever one.
	-h|--help) sed -n '2,${/^#/!q; s/^#//; s/^ //; p;}' "$0"; exit 0 ;;
esac
REPO="${1:-wes/mind}"
want() { [[ "$SECTION" == "all" || "$SECTION" == "$1" ]] }

print -P "Setting secrets on %F{cyan}$REPO%f"
print

gh auth status >/dev/null 2>&1 || { print "Run 'gh auth login' first."; exit 1 }
gh repo view "$REPO" >/dev/null 2>&1 || { print "Cannot see $REPO. Wrong name, or no access."; exit 1 }

# `openssl` on a Mac may be Apple's LibreSSL or Homebrew's OpenSSL 3, and they
# disagree about .p12 files in opposite directions: OpenSSL 3 refuses the old
# ciphers Keychain Access has historically exported unless it is given -legacy,
# while LibreSSL has no such flag and fails if handed one. Rather than guess
# which is in PATH, try plain and fall back to -legacy.
P12_LEGACY=()
p12() {   # p12 <args...> -- run openssl pkcs12 whichever way this build wants
	openssl pkcs12 "$@" ${P12_LEGACY[@]} 2>/dev/null
}
pick_p12_mode() {   # pick_p12_mode <file> <password>
	P12_LEGACY=()
	openssl pkcs12 -in "$1" -passin pass:"$2" -nokeys -noout >/dev/null 2>&1 && return 0
	if openssl pkcs12 -in "$1" -passin pass:"$2" -nokeys -noout -legacy >/dev/null 2>&1; then
		P12_LEGACY=(-legacy)
		return 0
	fi
	return 1
}

ask_file() {   # ask_file <prompt> -> path on stdout
	local p
	while true; do
		read "p?$1: "
		p="${p//\"/}"; p="${p/#\~/$HOME}"
		[[ -f "$p" ]] && { print -r -- "$p"; return }
		print "  no file at that path, try again" >&2
	done
}

# ---------------------------------------------------------------- certificate

if want cert; then
cat <<'NOTE'
1/2  Developer ID certificate
     Keychain Access > My Certificates > right-click
     "Developer ID Application: Wes Edling (288BJX6YHP)" > Export...
     Save as .p12 and set an export password when prompted.

     Expand the certificate and export the identity itself, not just the
     certificate row. A .p12 without the private key cannot sign anything,
     and it is the single most common way this goes wrong.
NOTE
P12=$(ask_file "     Path to the .p12")

while true; do
	read -s "P12PASS?     The export password you just set: "; print
	pick_p12_mode "$P12" "$P12PASS" && break
	print -P "     %F{red}That password does not open this .p12.%f Try again, or Ctrl-C and re-export."
done

# The private key is the half that actually signs. `security import` accepts a
# certificate-only .p12 happily and CI then falls over at codesign time.
if ! p12 -in "$P12" -passin pass:"$P12PASS" -nocerts -nodes | grep -q 'PRIVATE KEY'; then
	print -P "     %F{red}That .p12 has no private key in it.%f"
	print    "     In Keychain Access, expand the certificate with the arrow and export"
	print    "     the identity, so the key goes with it."
	exit 1
fi

CERT_PEM=$(p12 -in "$P12" -passin pass:"$P12PASS" -nokeys -clcerts)
# LibreSSL prints "subject= /CN=.../O=..." and OpenSSL 3 prints
# "subject=CN = ..., O = ...", so trim on whichever separator turns up.
SUBJECT=$(print -r -- "$CERT_PEM" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN *= *//; s|/.*||; s/,.*//')
EXPIRES=$(print -r -- "$CERT_PEM" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
[[ -n "$SUBJECT" ]] && print -P "     identity: %F{cyan}${SUBJECT}%f"
[[ -n "$EXPIRES" ]] && print    "     expires:  $EXPIRES"

if [[ -n "$SUBJECT" && "$SUBJECT" != *"Developer ID Application"* ]]; then
	print -P "     %F{yellow}Warning:%f that is not a Developer ID Application certificate."
	print    "     Only that kind can sign software for distribution outside the App Store."
	read "GOAHEAD?     Store it anyway? [y/N] "
	[[ "$GOAHEAD" == [yY]* ]] || exit 1
fi

# A certificate that expires mid-cycle fails every build from that day on, with
# nothing in the diff to explain it. Better to hear it now than in six months.
if ! print -r -- "$CERT_PEM" | openssl x509 -checkend 0 -noout >/dev/null 2>&1; then
	print -P "     %F{red}This certificate has already expired.%f Create a new one first."
	exit 1
elif ! print -r -- "$CERT_PEM" | openssl x509 -checkend 2592000 -noout >/dev/null 2>&1; then
	print -P "     %F{yellow}Heads up:%f this expires within 30 days."
fi

base64 -i "$P12" | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPO"
printf '%s' "$P12PASS" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO"
unset P12PASS
print -P "     %F{green}certificate stored and verified%f"
print
fi

# ------------------------------------------------------------------ notary key

if want notary; then
cat <<'NOTE'
2/2  Notary API key
     App Store Connect > Users and Access > Integrations > Keys >
     generate a key with the "Developer" role and download the .p8.
     It can only be downloaded once.
NOTE
P8=$(ask_file "     Path to the .p8")
grep -q 'BEGIN PRIVATE KEY' "$P8" \
	|| { print -P "     %F{red}That file is not a PEM private key.%f"; exit 1 }

DEFAULT_KEYID="${$(basename "$P8")#AuthKey_}"; DEFAULT_KEYID="${DEFAULT_KEYID%.p8}"
read "KEYID?     Key ID [${DEFAULT_KEYID}]: "
KEYID="${KEYID:-$DEFAULT_KEYID}"

# Team keys carry an issuer UUID; Individual keys have none, and notarytool
# errors if given one. Accept blank, and reject anything that is not a UUID
# rather than letting the runner discover it.
while true; do
	read "ISSUER?     Issuer ID (UUID; leave blank for an Individual key): "
	[[ -z "$ISSUER" ]] && break
	[[ "$ISSUER" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && break
	print -P "     %F{red}That is not a UUID.%f It is shown above the key list in App Store Connect,"
	print    "     and looks like 69a6de70-0000-1111-2222-3a4b5c6d7e8f. Blank for an Individual key."
done

# Ask Apple whether these credentials actually work, rather than only checking
# that they are shaped correctly. This is the same call notarize.sh makes, so a
# key that passes here will notarize.
print -n "     checking the key against Apple... "
NOTARY_ARGS=(--key "$P8" --key-id "$KEYID")
[[ -n "$ISSUER" ]] && NOTARY_ARGS+=(--issuer "$ISSUER")
if ERR=$(xcrun notarytool history "${NOTARY_ARGS[@]}" 2>&1 >/dev/null); then
	print -P "%F{green}accepted%f"
else
	print -P "%F{red}rejected%f"
	print -r -- "$ERR" | sed 's/^/       /'
	print
	if [[ -n "$ISSUER" ]]; then
		print "     If this is an Individual key rather than a Team key, run again and"
		print "     leave the issuer blank — notarytool rejects a key given one it has no use for."
	else
		print "     If this is a Team key, run again and supply the issuer UUID."
	fi
	exit 1
fi

base64 -i "$P8"       | gh secret set APPLE_API_KEY_P8 --repo "$REPO"
printf '%s' "$KEYID"  | gh secret set APPLE_API_KEY_ID --repo "$REPO"
if [[ -n "$ISSUER" ]]; then
	printf '%s' "$ISSUER" | gh secret set APPLE_API_ISSUER_ID --repo "$REPO"
else
	# Leaving a stale issuer behind would break an Individual key on the next run.
	gh secret delete APPLE_API_ISSUER_ID --repo "$REPO" 2>/dev/null || true
	print -P "     %F{cyan}Individual key: issuer secret removed%f"
fi
print -P "     %F{green}notary key stored and verified%f"

# The same credentials, kept locally, so ./scripts/notarize.sh works by hand
# without re-entering any of this.
read "STORELOCAL?     Also save these locally as the 'mind' keychain profile? [Y/n] "
if [[ "$STORELOCAL" != [nN]* ]]; then
	xcrun notarytool store-credentials mind "${NOTARY_ARGS[@]}" >/dev/null \
		&& print -P "     %F{green}local profile 'mind' saved%f" \
		|| print -P "     %F{yellow}could not save the local profile (the repo secrets are fine)%f"
fi
print
fi

print "Secrets now on $REPO:"
gh secret list --repo "$REPO" | sed 's/^/  /'
