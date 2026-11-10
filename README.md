# Emailwiz: Debian and Arch mail server installer

This branch provides one POSIX-shell installer for **Debian-family** and
**Arch-family** systemd servers. Distribution detection is automatic from
`/etc/os-release`; package names and configuration paths are selected by
platform.

Run a no-change preview first:

```sh
sudo ./emailwiz.sh --dry-run --domain example.com
```

Then install:

```sh
sudo ./emailwiz.sh --domain example.com
```

Use `--subdomain mx` to replace the default `mail.example.com` hostname. If a
certificate is not already present, Certbot requests one. For an isolated test
server, pass `--self-signed` instead.

The installer is designed to be rerunnable: generated files are installed
atomically, backups use the `.emailwiz-backup` suffix, and existing DKIM keys
are retained.

## This script installs

- **Postfix** to send and receive mail.
- **Dovecot** to provide IMAP, POP3, authentication, and Sieve filtering.
- **SpamAssassin** to classify spam into each user's Junk mailbox.
- **OpenDKIM** to sign outgoing mail.
- **Certbot** for TLS certificates and renewal hooks.
- **fail2ban** jails for Postfix and Dovecot.

## This script does _not_

- use a SQL database or anything like that.
- set up a graphical interface for mail like Roundcube or Squirrel Mail. If you
  want that, you'll have to install it yourself. I just use
  [isync/msmtp/mutt-wizard](https://github.com/lukesmithxyz/mutt-wizard) to
  have an offline mirror of my email setup and I recommend the same. There are
  other ways of doing it though, like Thunderbird, etc.

## Requirements

1. A fresh, fully updated, **systemd-based Debian, Ubuntu, Arch Linux, Manjaro,
   or EndeavourOS server** with a static public IP. Artix is not supported.
2. Root access. Arch systems should be fully upgraded with `pacman -Syu` before
   running the installer; emailwiz deliberately does not perform a partial
   repository refresh.
3. An `A`/`AAAA` record for `mail.example.com` pointing to the server. Port 80
   must be reachable while Certbot uses its standalone authenticator.
4. Reverse DNS from the server's public IP to the mail hostname. Many receiving
   providers reject mail with missing or mismatched PTR records.
5. Provider and host firewalls must allow TCP ports 25, 80, 110, 465, 587, 993,
   and 995. Some VPS providers require a support request before opening port 25.
6. Dovecot 2.3 or 2.4. Emailwiz detects the installed version and generates the
   corresponding configuration syntax; current Arch packages use the 2.4
   renderer.

Do not purge a working mail server before running emailwiz. Review the dry run
and back up existing configuration first.

## Operation and validation

```sh
# Preview Debian or Arch selection without changing the machine
sudo ./emailwiz.sh --dry-run --domain example.com

# Validate configuration and service health after installation
sudo ./emailwiz.sh --check --domain example.com

# Restore pre-install configuration (current config is saved under /var/backups)
sudo ./mailrm.sh

# Restore configuration and also remove installed mail packages
sudo ./mailrm.sh --purge-packages
```

Automated platform/input checks can be run with:

```sh
sh -n emailwiz.sh mailrm.sh tests/platform_test.sh
sh tests/platform_test.sh
shellcheck -s sh emailwiz.sh mailrm.sh tests/platform_test.sh
```

## Post-install requirements

- Add the MX, DKIM, DMARC, and SPF records written to
  `/var/lib/emailwiz/dns-records.txt`.
- Run `emailwiz.sh --check --domain example.com` after DNS propagation and after
  upgrades.
- Send test mail in both directions and verify TLS, SMTP authentication, IMAP,
  DKIM, SPF, DMARC, and reverse DNS before relying on the server.

## Making new users/mail accounts

Let's say we want to add a user Billy and let him receive mail, run this:

```
useradd -m -G mail billy
passwd billy
```

Any user added to the `mail` group will be able to receive mail. Suppose a user
Cassie already exists and we want to let her receive mail too. Just run:

```
usermod -a -G mail cassie
```

A user's mail will appear in `~/Mail/`. If you want to see your mail while ssh'd
in the server, you could just install mutt, add `set spoolfile="+Inbox"` to
your `~/.muttrc` and use mutt to view and reply to mail. You'll probably want
to log in remotely though:

## Logging in from Thunderbird or mutt (and others) remotely

Let's say you want to access your mail with Thunderbird or mutt or another
email program. For my domain, the server information will be as follows:

- SMTP server: `mail.lukesmith.xyz`
- SMTP port: 587
- IMAP server: `mail.lukesmith.xyz`
- IMAP port: 993

In previous versions of emailwiz, you also had to log on with *only* your
username (i.e. `luke`) rather than your whole email address (i.e.
`luke@lukesmith.xyz`), which caused some confusion. This is no longer the
case.

## Benefited from this?

I am always glad to hear this script is still making life easy for people!  If
this script or documentation has saved you some frustration, you can donate to
support me at [lukesmith.xyz/donate](https://lukesmith.xyz/donate.html).

## Troubleshooting -- Can't send mail?

- Always check `journalctl -xe` to see the specific problem.
- Check with your VPS host and ask them to enable mail ports. Some providers
  disable them by default. It shouldn't take any time.
- Go to [this site](https://appmaildev.com/en/dkim) to test your TXT records.
  If your DKIM, SPF or DMARC tests fail you probably copied in the TXT records
  incorrectly.
- If everything looks good and you *can* send mail, but it still goes to Gmail
  or another big provider's spam directory, your domain (especially if it's a
  new one) might be on a public spam list.  Check
  [this site](https://mxtoolbox.com/blacklists.aspx) to see if it is. Don't
  worry if you are: sometimes especially new domains are automatically assumed
  to be spam temporarily. If you are blacklisted by one of these, look into it
  and it will explain why and how to remove yourself.
- Check your DNS settings using [this site](https://intodns.com/), it'll report
  any issues with your MX records
- Ensure that port 25 is open on your server.
  [Vultr](https://www.vultr.com/docs/what-ports-are-blocked) for instance
  blocks this by default, you need to open a support ticket with them to open
  it. You can't send mail if 25 is blocked
