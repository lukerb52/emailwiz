#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
script=$repo_dir/emailwiz.sh
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' 0 1 2 15

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

pass() { printf 'ok - %s\n' "$1"; }

cat >"$tmp_dir/debian" <<'EOF'
ID=debian
VERSION_ID="12"
EOF
cat >"$tmp_dir/ubuntu" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
cat >"$tmp_dir/arch" <<'EOF'
ID=arch
EOF
cat >"$tmp_dir/manjaro" <<'EOF'
ID=manjaro
ID_LIKE="arch"
EOF

check_detection() {
	fixture=$1
	expected=$2
	actual=$(
		# shellcheck source=../emailwiz.sh
		# shellcheck disable=SC1090,SC1091
		EMAILWIZ_SOURCE_ONLY=1 EMAILWIZ_OS_RELEASE="$tmp_dir/$fixture" . "$script"
		PLATFORM=
		detect_platform
		printf '%s' "$PLATFORM"
	)
	[ "$actual" = "$expected" ] || fail "$fixture detected as '$actual', expected '$expected'"
	pass "$fixture platform detection"
}

check_detection debian debian
check_detection ubuntu debian
check_detection arch arch
check_detection manjaro arch

# shellcheck source=../emailwiz.sh
# shellcheck disable=SC1090,SC1091
EMAILWIZ_SOURCE_ONLY=1 . "$script"
unset EMAILWIZ_SOURCE_ONLY
for domain in example.com mail.example.co.uk a-b.example; do
	validate_domain "$domain" || fail "valid domain rejected: $domain"
done
for domain in localhost .example.com example..com -bad.example bad_.example; do
	if validate_domain "$domain"; then fail "invalid domain accepted: $domain"; fi
done
pass "domain validation"

"$script" --dry-run --distro debian --domain example.com >/dev/null
"$script" --dry-run --distro arch --domain example.com >/dev/null
pass "Debian and Arch dry runs"

if "$script" --dry-run --distro arch --domain invalid >/dev/null 2>&1; then
	fail "invalid CLI domain was accepted"
fi
pass "invalid CLI input fails"

printf 'All platform tests passed.\n'
