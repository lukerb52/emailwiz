#!/bin/sh

# emailwiz: configure a Postfix/Dovecot mail server on Debian or Arch.
# POSIX sh is used deliberately so the script works with Debian's dash.

set -eu
umask 0022

PROGRAM=${0##*/}
MODE=apply
PLATFORM=${EMAILWIZ_DISTRO_FAMILY:-}
OS_RELEASE_FILE=${EMAILWIZ_OS_RELEASE:-/etc/os-release}
DOMAIN=${MAIL_DOMAIN:-}
SUBDOMAIN=${MAIL_SUBDOM:-mail}
CERT_DIR=${MAIL_CERT_DIR:-}
SELF_SIGNED=${EMAILWIZ_SELF_SIGNED:-no}
LOCK_DIR=/run/emailwiz.lock
STATE_DIR=/var/lib/emailwiz
DNS_OUTPUT=
SPAMD_USER=
OPENDKIM_CONF=
PACKAGES=
DOVECOT_CONFIG=
SPAMC_PATH=
SENDMAIL_PATH=
SA_UPDATE_PATH=
SA_TIMER=emailwiz-sa-update.timer

log() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<EOF
Usage: $PROGRAM [--dry-run | --check] [options]

Options:
  --domain DOMAIN       Mail domain, for example example.org
  --subdomain LABEL     Mail host and DKIM selector (default: mail)
  --cert-dir PATH       Existing certificate directory
  --self-signed         Generate a long-lived self-signed certificate
  --distro FAMILY       Override detection with debian or arch
  --dns-output PATH     DNS record output path
  --dry-run             Print the installation plan without changing anything
  --check               Validate an existing installation without changing it
  -h, --help            Show this help

Environment defaults: MAIL_DOMAIN, MAIL_SUBDOM, MAIL_CERT_DIR,
EMAILWIZ_SELF_SIGNED, EMAILWIZ_DISTRO_FAMILY, and EMAILWIZ_OS_RELEASE.
EOF
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case $1 in
			--domain) [ "$#" -ge 2 ] || die "--domain needs a value"; DOMAIN=$2; shift 2 ;;
			--subdomain) [ "$#" -ge 2 ] || die "--subdomain needs a value"; SUBDOMAIN=$2; shift 2 ;;
			--cert-dir) [ "$#" -ge 2 ] || die "--cert-dir needs a value"; CERT_DIR=$2; shift 2 ;;
			--distro) [ "$#" -ge 2 ] || die "--distro needs a value"; PLATFORM=$2; shift 2 ;;
			--dns-output) [ "$#" -ge 2 ] || die "--dns-output needs a value"; DNS_OUTPUT=$2; shift 2 ;;
			--self-signed) SELF_SIGNED=yes; shift ;;
			--dry-run) MODE=dry-run; shift ;;
			--check) MODE=check; shift ;;
			-h|--help) usage; exit 0 ;;
			*) die "unknown option: $1" ;;
		esac
	done
}

os_release_value() {
	key=$1
	file=$2
	[ -r "$file" ] || return 1
	awk -F= -v key="$key" '
		$1 == key {
			value = substr($0, index($0, "=") + 1)
			gsub(/^\047|\047$/, "", value)
			gsub(/^\042|\042$/, "", value)
			print value
			exit
		}' "$file"
}

detect_platform() {
	if [ -z "$PLATFORM" ]; then
		id=$(os_release_value ID "$OS_RELEASE_FILE" || true)
		like=$(os_release_value ID_LIKE "$OS_RELEASE_FILE" || true)
		case " $id $like " in
			*' arch '*) PLATFORM=arch ;;
			*' debian '*|*' ubuntu '*) PLATFORM=debian ;;
			*) die "unsupported distribution '$id' (ID_LIKE='$like')" ;;
		esac
	fi

	case $PLATFORM in
		debian)
			PACKAGES="postfix postfix-pcre dovecot-imapd dovecot-pop3d dovecot-sieve opendkim opendkim-tools spamassassin spamc fail2ban bind9-host certbot ca-certificates"
			SPAMD_USER=debian-spamd
			OPENDKIM_CONF=/etc/opendkim.conf
			;;
		arch)
			PACKAGES="postfix dovecot pigeonhole opendkim spamassassin fail2ban bind certbot ca-certificates"
			SPAMD_USER=spamd
			OPENDKIM_CONF=/etc/opendkim/opendkim.conf
			;;
		*) die "unsupported distribution family: $PLATFORM" ;;
	esac
}

validate_label() {
	label=$1
	[ -n "$label" ] || return 1
	[ "${#label}" -le 63 ] || return 1
	case $label in
		-*|*-|*[!a-z0-9-]*) return 1 ;;
	esac
	return 0
}

validate_domain() {
	value=$1
	[ -n "$value" ] || return 1
	[ "${#value}" -le 253 ] || return 1
	case $value in
		.*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
	esac
	old_ifs=$IFS
	IFS=.
	# Splitting on dots is intentional; pathname expansion is disabled.
	set -f
	# shellcheck disable=SC2086
	set -- $value
	set +f
	IFS=$old_ifs
	[ "$#" -ge 2 ] || return 1
	for label do validate_label "$label" || return 1; done
	return 0
}

collect_inputs() {
	if [ -z "$DOMAIN" ] && [ -r /etc/mailname ]; then
		IFS= read -r DOMAIN </etc/mailname || true
	fi
	if [ -z "$DOMAIN" ] && have hostname; then
		DOMAIN=$(hostname -d 2>/dev/null || true)
	fi
	DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
	DOMAIN=${DOMAIN%.}
	SUBDOMAIN=$(printf '%s' "$SUBDOMAIN" | tr '[:upper:]' '[:lower:]')
	validate_domain "$DOMAIN" || die "provide a valid public domain with --domain"
	validate_label "$SUBDOMAIN" || die "subdomain must be one DNS label"
	MAILDOMAIN=$SUBDOMAIN.$DOMAIN
	[ -n "$CERT_DIR" ] || CERT_DIR=/etc/letsencrypt/live/$MAILDOMAIN
	[ -n "$DNS_OUTPUT" ] || DNS_OUTPUT=$STATE_DIR/dns-records.txt
	case $SELF_SIGNED in yes|no) ;; *) die "EMAILWIZ_SELF_SIGNED must be yes or no" ;; esac
}

print_plan() {
	log "Platform:       $PLATFORM"
	log "Domain:         $DOMAIN"
	log "Mail host:      $MAILDOMAIN"
	log "Certificate:    $CERT_DIR"
	log "OpenDKIM conf:  $OPENDKIM_CONF"
	log "SpamAssassin:   $SPAMD_USER"
	log "Packages:       $PACKAGES"
	log "DNS output:     $DNS_OUTPUT"
}

require_root() {
	[ "$(id -u)" -eq 0 ] || die "apply mode must run as root"
	[ -d /run/systemd/system ] || die "emailwiz currently requires systemd"
	mkdir "$LOCK_DIR" 2>/dev/null || die "another emailwiz process is running ($LOCK_DIR exists)"
	trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' 0 1 2 15
}

install_packages() {
	log "Installing required packages for $PLATFORM..."
	case $PLATFORM in
		debian)
			have apt-get || die "apt-get is unavailable"
			DEBIAN_FRONTEND=noninteractive apt-get update
			# Word splitting is intentional for this static capability list.
			# shellcheck disable=SC2086
			DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES
			;;
		arch)
			have pacman || die "pacman is unavailable"
			# Do not use -Sy: partial upgrades are unsupported on Arch.
			# shellcheck disable=SC2086
			pacman -S --needed --noconfirm $PACKAGES
			;;
	esac
}

require_commands() {
	missing=
	for command_name in postconf postfix newaliases doveconf dovecot sievec opendkim-genkey spamc systemctl openssl; do
		have "$command_name" || missing="$missing $command_name"
	done
	[ -z "$missing" ] || die "required commands are missing:$missing"
	SPAMC_PATH=$(command -v spamc)
	SENDMAIL_PATH=$(command -v sendmail 2>/dev/null || true)
	[ -n "$SENDMAIL_PATH" ] || die "sendmail compatibility command is missing"
	SA_UPDATE_PATH=$(command -v sa-update 2>/dev/null || true)
	[ -n "$SA_UPDATE_PATH" ] || die "sa-update is missing"
}

install_stdin_file() {
	path=$1
	mode=$2
	if [ "$MODE" = dry-run ]; then
		log "Would install $path (mode $mode)"
		cat >/dev/null
		return 0
	fi
	parent=${path%/*}
	[ "$parent" = "$path" ] && parent=.
	mkdir -p "$parent"
	tmp=$(mktemp "$parent/.emailwiz.XXXXXX") || die "cannot create temporary file for $path"
	cat >"$tmp" || { rm -f "$tmp"; die "cannot write $path"; }
	chmod "$mode" "$tmp"
	if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
		rm -f "$tmp"
	else
		[ ! -e "$path" ] || cp -p "$path" "$path.emailwiz-backup"
		mv "$tmp" "$path"
		log "Installed $path"
	fi
}

set_config_value() {
	file=$1
	key=$2
	value=$3
	if [ "$MODE" = dry-run ]; then
		log "Would set $key in $file"
		return 0
	fi
	mkdir -p "${file%/*}"
	[ -f "$file" ] || : >"$file"
	tmp=$(mktemp "${file%/*}/.emailwiz.XXXXXX") || die "cannot update $file"
	awk -v key="$key" -v value="$value" '
		$0 ~ "^[[:space:]#]*" key "[[:space:]]" { next }
		{ print }
		END { print key " " value }
	' "$file" >"$tmp" || { rm -f "$tmp"; die "cannot update $file"; }
	chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
	mv "$tmp" "$file"
}

backup_configs() {
	backup_dir=$STATE_DIR/backups
	mkdir -p "$backup_dir"
	for source_path in /etc/mailname /etc/aliases /etc/postfix/main.cf /etc/postfix/master.cf /etc/dovecot/dovecot.conf "$OPENDKIM_CONF"; do
		[ -f "$source_path" ] || continue
		backup_name=$(printf '%s' "$source_path" | sed 's|^/||; s|/|__|g')
		[ -e "$backup_dir/$backup_name" ] || cp -p "$source_path" "$backup_dir/$backup_name"
	done
	printf '%s\n%s\n' "$DOMAIN" "$SUBDOMAIN" | install_stdin_file "$STATE_DIR/identity" 600
}

configure_aliases() {
	[ -f /etc/aliases ] || : >/etc/aliases
	tmp=$(mktemp /etc/.emailwiz-aliases.XXXXXX) || die "cannot update /etc/aliases"
	awk '
		$0 ~ "^[[:space:]]*postmaster[[:space:]]*:" { next }
		{ print }
		END { print "postmaster: root" }
	' /etc/aliases >"$tmp"
	chmod --reference=/etc/aliases "$tmp" 2>/dev/null || chmod 644 "$tmp"
	mv "$tmp" /etc/aliases
	newaliases
}

ensure_certificate() {
	if [ -r "$CERT_DIR/fullchain.pem" ] && [ -r "$CERT_DIR/privkey.pem" ]; then
		log "Using certificate in $CERT_DIR"
		return 0
	fi
	if [ "$SELF_SIGNED" = yes ]; then
		openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
			-subj "/CN=$MAILDOMAIN" \
			-keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem"
		chmod 600 "$CERT_DIR/privkey.pem"
		return 0
	fi

	have certbot || die "certbot was not installed"
	if systemctl -q is-active nginx.service 2>/dev/null; then
		case $PLATFORM in
			debian) DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-nginx ;;
			arch) pacman -S --needed --noconfirm certbot-nginx ;;
		esac
		certbot certonly --nginx -d "$MAILDOMAIN" --non-interactive --register-unsafely-without-email --agree-tos
	elif systemctl -q is-active apache2.service 2>/dev/null || systemctl -q is-active httpd.service 2>/dev/null; then
		case $PLATFORM in
			debian) DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-apache ;;
			arch) pacman -S --needed --noconfirm certbot-apache ;;
		 esac
		certbot certonly --apache -d "$MAILDOMAIN" --non-interactive --register-unsafely-without-email --agree-tos
	else
		certbot certonly --standalone -d "$MAILDOMAIN" --non-interactive --register-unsafely-without-email --agree-tos
	fi
	if [ ! -r "$CERT_DIR/fullchain.pem" ] || [ ! -r "$CERT_DIR/privkey.pem" ]; then
		die "certificate creation failed"
	fi
}

configure_postfix() {
	log "Configuring Postfix..."
	postconf -e "myhostname = $MAILDOMAIN"
	postconf -e "mydomain = $DOMAIN"
	# These dollar expressions belong to Postfix, not the shell.
	# shellcheck disable=SC2016
	postconf -e 'myorigin = $mydomain'
	# shellcheck disable=SC2016
	postconf -e 'mydestination = $myhostname, $mydomain, localhost.$mydomain, localhost'
	postconf -e 'home_mailbox = Mail/Inbox/'
	postconf -e "smtpd_tls_key_file = $CERT_DIR/privkey.pem"
	postconf -e "smtpd_tls_cert_file = $CERT_DIR/fullchain.pem"
	postconf -e 'smtpd_tls_security_level = may'
	postconf -e 'smtp_tls_security_level = may'
	postconf -e 'smtpd_tls_auth_only = yes'
	postconf -e 'smtpd_tls_mandatory_protocols = >=TLSv1.2'
	postconf -e 'smtp_tls_mandatory_protocols = >=TLSv1.2'
	postconf -e 'smtpd_sasl_auth_enable = yes'
	postconf -e 'smtpd_sasl_type = dovecot'
	postconf -e 'smtpd_sasl_path = private/auth'
	postconf -e 'smtpd_sasl_security_options = noanonymous'
	postconf -e 'smtpd_sasl_tls_security_options = noanonymous'
	postconf -e 'smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination'
	postconf -e 'smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, reject_unknown_recipient_domain'
	postconf -e 'smtpd_helo_required = yes'
	postconf -e 'smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname'
	postconf -e 'smtpd_sender_login_maps = pcre:/etc/postfix/emailwiz_login_maps.pcre'
	postconf -e 'smtpd_sender_restrictions = reject_sender_login_mismatch, permit_sasl_authenticated, permit_mynetworks, reject_unknown_sender_domain'
	postconf -e 'header_checks = regexp:/etc/postfix/emailwiz_header_checks'
	postconf -e 'milter_default_action = accept'
	postconf -e 'milter_protocol = 6'
	postconf -e 'smtpd_milters = inet:localhost:12301'
	postconf -e 'non_smtpd_milters = inet:localhost:12301'
	if postconf -d smtpd_forbid_bare_newline >/dev/null 2>&1; then
		postconf -e 'smtpd_forbid_bare_newline = normalize'
		# shellcheck disable=SC2016
		postconf -e 'smtpd_forbid_bare_newline_exclusions = $mynetworks'
	fi

	escaped_domain=$(printf '%s' "$DOMAIN" | sed 's/[.]/\\./g')
	# ${1} is a Postfix PCRE replacement, not a shell expression.
	# shellcheck disable=SC2016
	printf '/^(.*)@%s$/   ${1}\n' "$escaped_domain" | install_stdin_file /etc/postfix/emailwiz_login_maps.pcre 644
	cat <<'EOF' | install_stdin_file /etc/postfix/emailwiz_header_checks 644
/^Received:.*with ESMTPSA/    IGNORE
/^X-Originating-IP:/         IGNORE
EOF

	lda=$(command -v dovecot-lda 2>/dev/null || true)
	[ -n "$lda" ] || [ ! -x /usr/lib/dovecot/dovecot-lda ] || lda=/usr/lib/dovecot/dovecot-lda
	[ -n "$lda" ] || die "cannot locate dovecot-lda"
	postconf -e "mailbox_command = $lda"

	postconf -M "submission/inet=submission inet n - y - - smtpd"
	postconf -P 'submission/inet/syslog_name=postfix/submission'
	postconf -P 'submission/inet/smtpd_tls_security_level=encrypt'
	postconf -P 'submission/inet/smtpd_tls_auth_only=yes'
	postconf -P 'submission/inet/smtpd_sasl_auth_enable=yes'
	postconf -P 'submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject'
	postconf -M "smtps/inet=smtps inet n - y - - smtpd"
	postconf -P 'smtps/inet/syslog_name=postfix/smtps'
	postconf -P 'smtps/inet/smtpd_tls_wrappermode=yes'
	postconf -P 'smtps/inet/smtpd_sasl_auth_enable=yes'
	postconf -P 'smtp/inet/content_filter=spamassassin'
	postconf -M "spamassassin/unix=spamassassin unix - n n - - pipe flags=Rq user=$SPAMD_USER argv=$SPAMC_PATH -f -e $SENDMAIL_PATH -oi -f \${sender} \${recipient}"
}

configure_dovecot() {
	log "Configuring Dovecot $DOVECOT_CONFIG syntax..."
	case $DOVECOT_CONFIG in
		23)
			cat <<EOF | install_stdin_file /etc/dovecot/conf.d/99-emailwiz.conf 644
# Managed by emailwiz. Local overrides should use a later include filename.
protocols = imap pop3
ssl = required
ssl_cert = <$CERT_DIR/fullchain.pem
ssl_key = <$CERT_DIR/privkey.pem
ssl_min_protocol = TLSv1.2
auth_mechanisms = plain login
auth_username_format = %n
mail_location = maildir:~/Mail:INBOX=~/Mail/Inbox:LAYOUT=fs

namespace inbox {
  inbox = yes
  mailbox Drafts {
    special_use = \\Drafts
    auto = subscribe
  }
  mailbox Junk {
    special_use = \\Junk
    auto = subscribe
    autoexpunge = 30d
  }
  mailbox Sent {
    special_use = \\Sent
    auto = subscribe
  }
  mailbox Trash {
    special_use = \\Trash
  }
  mailbox Archive {
    special_use = \\Archive
  }
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
protocol lda { mail_plugins = \$mail_plugins sieve }
protocol lmtp { mail_plugins = \$mail_plugins sieve }
plugin {
  sieve = ~/.dovecot.sieve
  sieve_default = /var/lib/dovecot/sieve/default.sieve
  sieve_dir = ~/.sieve
  sieve_global_dir = /var/lib/dovecot/sieve/
}
EOF
			;;
		24)
			cat <<EOF | install_stdin_file /etc/dovecot/dovecot.conf 644
# Managed by emailwiz for Dovecot 2.4. The original is in
# /var/lib/emailwiz/backups/ and is restored by mailrm.sh.
dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0

protocols {
  imap = yes
  pop3 = yes
}
passdb pam {
}
userdb passwd {
}
ssl = required
ssl_server_cert_file = $CERT_DIR/fullchain.pem
ssl_server_key_file = $CERT_DIR/privkey.pem
ssl_min_protocol = TLSv1.2
auth_mechanisms = plain login
auth_username_format = %{user | username}
mail_driver = maildir
mail_path = ~/Mail
mail_inbox_path = ~/Mail/Inbox

namespace inbox {
  inbox = yes
  mailbox Drafts {
    special_use = \\Drafts
    auto = subscribe
  }
  mailbox Junk {
    special_use = \\Junk
    auto = subscribe
    autoexpunge = 30d
  }
  mailbox Sent {
    special_use = \\Sent
    auto = subscribe
  }
  mailbox Trash {
    special_use = \\Trash
  }
  mailbox Archive {
    special_use = \\Archive
  }
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
protocol lda {
  mail_plugins {
    sieve = yes
  }
}
protocol lmtp {
  mail_plugins {
    sieve = yes
  }
}
sieve_script personal {
  driver = file
  path = ~/.sieve
  active_path = ~/.dovecot.sieve
}
sieve_script emailwiz_default {
  type = default
  driver = file
  path = /var/lib/dovecot/sieve/default.sieve
}
EOF
			;;
		*) die "unsupported Dovecot configuration generation: $DOVECOT_CONFIG" ;;
	esac

	mkdir -p /var/lib/dovecot/sieve
	cat <<'EOF' | install_stdin_file /var/lib/dovecot/sieve/default.sieve 644
require ["fileinto", "mailbox"];
if header :contains "X-Spam-Flag" "YES" {
  fileinto :create "Junk";
}
EOF
	sievec /var/lib/dovecot/sieve/default.sieve
}

configure_opendkim() {
	log "Configuring OpenDKIM..."
	key_dir=/etc/postfix/dkim/$DOMAIN
	private_key=$key_dir/$SUBDOMAIN.private
	public_key=$key_dir/$SUBDOMAIN.txt
	mkdir -p "$key_dir"
	if [ ! -s "$private_key" ] || [ ! -s "$public_key" ]; then
		log "Generating a new DKIM key..."
		opendkim-genkey -b 2048 -D "$key_dir" -d "$DOMAIN" -s "$SUBDOMAIN"
	else
		log "Keeping the existing DKIM key"
	fi
	chown root:opendkim "$private_key" "$public_key"
	chmod 640 "$private_key"
	chmod 644 "$public_key"

	printf '%s._domainkey.%s %s:%s:%s\n' "$SUBDOMAIN" "$DOMAIN" "$DOMAIN" "$SUBDOMAIN" "$private_key" |
		install_stdin_file /etc/postfix/dkim/emailwiz-keytable 644
	printf '*@%s %s._domainkey.%s\n' "$DOMAIN" "$SUBDOMAIN" "$DOMAIN" |
		install_stdin_file /etc/postfix/dkim/emailwiz-signingtable 644
	cat <<'EOF' | install_stdin_file /etc/postfix/dkim/emailwiz-trustedhosts 644
127.0.0.1
::1
localhost
EOF

	set_config_value "$OPENDKIM_CONF" Syslog yes
	set_config_value "$OPENDKIM_CONF" UMask 007
	set_config_value "$OPENDKIM_CONF" Canonicalization relaxed/simple
	set_config_value "$OPENDKIM_CONF" Mode sv
	set_config_value "$OPENDKIM_CONF" SubDomains no
	set_config_value "$OPENDKIM_CONF" Socket inet:12301@localhost
	set_config_value "$OPENDKIM_CONF" KeyTable file:/etc/postfix/dkim/emailwiz-keytable
	set_config_value "$OPENDKIM_CONF" SigningTable refile:/etc/postfix/dkim/emailwiz-signingtable
	set_config_value "$OPENDKIM_CONF" ExternalIgnoreList refile:/etc/postfix/dkim/emailwiz-trustedhosts
	set_config_value "$OPENDKIM_CONF" InternalHosts refile:/etc/postfix/dkim/emailwiz-trustedhosts
}

configure_fail2ban() {
	cat <<'EOF' | install_stdin_file /etc/fail2ban/jail.d/emailwiz.local 644
[postfix]
enabled = true

[postfix-sasl]
enabled = true

[dovecot]
enabled = true
EOF
}

configure_timers() {
	if systemctl list-unit-files spamassassin-update.timer --no-legend 2>/dev/null | grep -q '^spamassassin-update.timer'; then
		SA_TIMER=spamassassin-update.timer
	else
		SA_TIMER=emailwiz-sa-update.timer
		cat <<EOF | install_stdin_file /etc/systemd/system/emailwiz-sa-update.service 644
[Unit]
Description=Update SpamAssassin rules

[Service]
Type=oneshot
ExecStart=-$SA_UPDATE_PATH
ExecStartPost=/usr/bin/systemctl try-reload-or-restart spamassassin.service
EOF
		cat <<'EOF' | install_stdin_file /etc/systemd/system/emailwiz-sa-update.timer 644
[Unit]
Description=Update SpamAssassin rules daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
	fi
	cat <<'EOF' | install_stdin_file /etc/letsencrypt/renewal-hooks/deploy/emailwiz-reload 755
#!/bin/sh
systemctl reload postfix.service dovecot.service
EOF
}

configure_firewall() {
	if have ufw; then
		for port in 25 80 110 465 587 993 995; do ufw allow "$port/tcp" >/dev/null; done
	elif have firewall-cmd && systemctl -q is-active firewalld.service; then
		for service_name in smtp smtp-submission smtps imap imaps pop3 pop3s http; do
			firewall-cmd --permanent --add-service="$service_name" >/dev/null 2>&1 || true
		done
		firewall-cmd --reload >/dev/null
	else
		warn "no supported firewall manager found; allow TCP ports 25, 80, 110, 465, 587, 993, and 995"
	fi
}

write_dns_records() {
	key_file=/etc/postfix/dkim/$DOMAIN/$SUBDOMAIN.txt
	pval=$(tr -d '\n\t\r "()' <"$key_file" | sed -n 's/.*p=\([^;]*\).*/\1/p')
	[ -n "$pval" ] || die "could not parse the DKIM public key"
	cat <<EOF | install_stdin_file "$DNS_OUTPUT" 600
$DOMAIN.  MX   10 $MAILDOMAIN.
$SUBDOMAIN._domainkey.$DOMAIN.  TXT  "v=DKIM1; k=rsa; p=$pval"
_dmarc.$DOMAIN.  TXT  "v=DMARC1; p=reject; rua=mailto:postmaster@$DOMAIN; fo=1"
$DOMAIN.  TXT  "v=spf1 mx a:$MAILDOMAIN -all"
EOF
}

validate_static() {
	log "Validating configuration..."
	failed=0
	for path in "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" "/etc/postfix/dkim/$DOMAIN/$SUBDOMAIN.private"; do
		[ -s "$path" ] || { warn "missing $path"; failed=1; }
	done
	postfix check || failed=1
	postconf -M >/dev/null || failed=1
	doveconf -n >/dev/null || failed=1
	[ -r "$OPENDKIM_CONF" ] || { warn "missing $OPENDKIM_CONF"; failed=1; }
	[ "$failed" -eq 0 ] || die "configuration validation failed"
}

enable_services() {
	systemctl daemon-reload
	for unit in opendkim.service spamassassin.service dovecot.service postfix.service fail2ban.service "$SA_TIMER"; do
		log "Enabling $unit..."
		systemctl enable --now "$unit"
	done
	for timer in certbot.timer certbot-renew.timer; do
		if systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "^$timer"; then
			systemctl enable --now "$timer"
		fi
	done
	for unit in opendkim.service spamassassin.service dovecot.service postfix.service; do
		systemctl -q is-active "$unit" || die "$unit did not start"
	done
}

run_check() {
	require_commands
	validate_static
	failed=0
	for unit in opendkim.service spamassassin.service dovecot.service postfix.service; do
		systemctl -q is-active "$unit" || { warn "$unit is not active"; failed=1; }
	done
	[ "$failed" -eq 0 ] || exit 1
	log "The emailwiz installation is healthy."
}

apply_installation() {
	require_root
	install_packages
	require_commands
	case $(dovecot --version 2>/dev/null) in
		2.2*|2.3*) DOVECOT_CONFIG=23 ;;
		2.4*) DOVECOT_CONFIG=24 ;;
		*) die "unsupported Dovecot version: $(dovecot --version 2>/dev/null)" ;;
	esac
	mkdir -p "$STATE_DIR"
	backup_configs
	if [ "$PLATFORM" = debian ]; then printf '%s\n' "$DOMAIN" > /etc/mailname; fi
	configure_firewall
	if [ "$SELF_SIGNED" = yes ]; then mkdir -p "$CERT_DIR"; fi
	ensure_certificate
	configure_aliases
	configure_postfix
	configure_dovecot
	configure_opendkim
	configure_fail2ban
	configure_timers
	write_dns_records
	validate_static
	enable_services
	log ""
	log "Installation complete. Add the DNS records from $DNS_OUTPUT."
	log "Then run: $PROGRAM --check --domain $DOMAIN"
}

main() {
	parse_args "$@"
	detect_platform
	collect_inputs
	print_plan
	case $MODE in
		dry-run)
			log ""
			log "Dry run only; no files, packages, or services were changed."
			log "Would install packages, provision TLS, configure Postfix/Dovecot/OpenDKIM,"
			log "enable fail2ban and maintenance timers, validate, and start services."
			;;
		check) run_check ;;
		apply) apply_installation ;;
	esac
}

if [ "${EMAILWIZ_SOURCE_ONLY:-0}" != 1 ]; then
	main "$@"
fi
