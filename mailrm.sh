#!/bin/sh

set -eu

PROGRAM=${0##*/}
PLATFORM=${EMAILWIZ_DISTRO_FAMILY:-}
YES=no
PURGE=no

usage() {
	cat <<EOF
Usage: $PROGRAM [--purge-packages] [--yes] [--distro debian|arch]

Removes configuration created by emailwiz while preserving users and mail.
Pre-install mail configuration is restored; current config is first copied to
/var/backups so post-install administrator changes remain recoverable.
Package removal is opt-in. Without --yes, confirmation is required.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
	case $1 in
		--purge-packages) PURGE=yes; shift ;;
		--yes) YES=yes; shift ;;
		--distro) [ "$#" -ge 2 ] || die "--distro needs a value"; PLATFORM=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

[ "$(id -u)" -eq 0 ] || die "run this helper as root"

if [ -z "$PLATFORM" ]; then
	[ -r /etc/os-release ] || die "cannot detect the distribution"
	id=$(awk -F= '$1 == "ID" { gsub(/^\042|\042$/, "", $2); print $2 }' /etc/os-release)
	like=$(awk -F= '$1 == "ID_LIKE" { gsub(/^\042|\042$/, "", $2); print $2 }' /etc/os-release)
	case " $id $like " in
		*' arch '*) PLATFORM=arch ;;
		*' debian '*|*' ubuntu '*) PLATFORM=debian ;;
		*) die "unsupported distribution: $id" ;;
	esac
fi
case $PLATFORM in debian|arch) ;; *) die "unsupported family: $PLATFORM" ;; esac

if [ "$YES" != yes ]; then
	printf 'Restore pre-emailwiz mail configuration%s? Current config will be backed up. [y/N] ' "$(if [ "$PURGE" = yes ]; then printf ' and remove packages'; fi)"
	IFS= read -r answer
	case $answer in y|Y|yes|YES) ;; *) printf 'Cancelled.\n'; exit 0 ;; esac
fi

if [ "$PURGE" = yes ]; then
	for unit in postfix dovecot opendkim spamassassin fail2ban; do
		systemctl disable --now "$unit" >/dev/null 2>&1 || true
	done
fi
systemctl disable --now emailwiz-sa-update.timer >/dev/null 2>&1 || true

backup_dir=/var/lib/emailwiz/backups
if [ -d "$backup_dir" ]; then
	rollback_dir=/var/backups/emailwiz-removal-$(date +%Y%m%d%H%M%S)
	mkdir -p "$rollback_dir"
	for mapping in \
		'etc__mailname:/etc/mailname' \
		'etc__aliases:/etc/aliases' \
		'etc__postfix__main.cf:/etc/postfix/main.cf' \
		'etc__postfix__master.cf:/etc/postfix/master.cf' \
		'etc__dovecot__dovecot.conf:/etc/dovecot/dovecot.conf'; do
		backup_name=${mapping%%:*}
		target=${mapping#*:}
		[ ! -f "$target" ] || cp -p "$target" "$rollback_dir/$backup_name"
		[ ! -f "$backup_dir/$backup_name" ] || cp -p "$backup_dir/$backup_name" "$target"
	done
	case $PLATFORM in
		debian) opendkim_target=/etc/opendkim.conf ;;
		arch) opendkim_target=/etc/opendkim/opendkim.conf ;;
	esac
	opendkim_backup=$(printf '%s' "$opendkim_target" | sed 's|^/||; s|/|__|g')
	[ ! -f "$opendkim_target" ] || cp -p "$opendkim_target" "$rollback_dir/$opendkim_backup"
	[ ! -f "$backup_dir/$opendkim_backup" ] || cp -p "$backup_dir/$opendkim_backup" "$opendkim_target"
	printf 'Current mail configuration saved in %s\n' "$rollback_dir"
	if command -v newaliases >/dev/null 2>&1; then newaliases || true; fi
elif command -v postconf >/dev/null 2>&1; then
	# Legacy installations did not record their original configuration.
	for parameter in mailbox_command header_checks smtpd_sender_login_maps smtpd_milters non_smtpd_milters; do
		postconf -X "$parameter" >/dev/null 2>&1 || true
	done
	postconf -PX smtp/inet/content_filter >/dev/null 2>&1 || true
	postconf -MX spamassassin/unix >/dev/null 2>&1 || true
fi

identity=/var/lib/emailwiz/identity
installed_domain=
installed_selector=
if [ -r "$identity" ]; then
	{
		IFS= read -r installed_domain || true
		IFS= read -r installed_selector || true
	} <"$identity"
fi
case $installed_domain:$installed_selector in
	*[!a-z0-9.-]*:*|*:*[!a-z0-9-]*)
		installed_domain=
		installed_selector=
		;;
esac

rm -f \
	/etc/dovecot/conf.d/99-emailwiz.conf \
	/etc/fail2ban/jail.d/emailwiz.local \
	/etc/postfix/emailwiz_header_checks \
	/etc/postfix/emailwiz_login_maps.pcre \
	/etc/systemd/system/emailwiz-sa-update.service \
	/etc/systemd/system/emailwiz-sa-update.timer \
	/etc/letsencrypt/renewal-hooks/deploy/emailwiz-reload \
	/var/lib/dovecot/sieve/default.sieve \
	/var/lib/dovecot/sieve/default.svbin \
	/etc/postfix/dkim/emailwiz-keytable \
	/etc/postfix/dkim/emailwiz-signingtable \
	/etc/postfix/dkim/emailwiz-trustedhosts
if [ -n "$installed_domain" ] && [ -n "$installed_selector" ]; then
	rm -f "/etc/postfix/dkim/$installed_domain/$installed_selector.private" \
		"/etc/postfix/dkim/$installed_domain/$installed_selector.txt"
	rmdir "/etc/postfix/dkim/$installed_domain" 2>/dev/null || true
fi
rmdir /etc/postfix/dkim /var/lib/dovecot/sieve /var/lib/dovecot 2>/dev/null || true
systemctl daemon-reload
if [ "$PURGE" != yes ]; then
	for unit in opendkim spamassassin dovecot postfix fail2ban; do
		systemctl try-restart "$unit" >/dev/null 2>&1 || true
	done
fi

if [ "$PURGE" = yes ]; then
	case $PLATFORM in
		debian)
			DEBIAN_FRONTEND=noninteractive apt-get purge -y postfix postfix-pcre dovecot-core dovecot-imapd dovecot-pop3d dovecot-sieve opendkim opendkim-tools spamassassin spamc fail2ban
			;;
		arch)
			installed=
			for package in postfix dovecot dovecot23 pigeonhole pigeonhole23 opendkim spamassassin fail2ban; do
				pacman -Q "$package" >/dev/null 2>&1 && installed="$installed $package"
			done
			if [ -n "$installed" ]; then
				# shellcheck disable=SC2086
				pacman -Rns --noconfirm $installed
			fi
			;;
	esac
fi

rm -rf /var/lib/emailwiz
printf 'Emailwiz configuration removed; user mail and TLS certificates were preserved.\n'
