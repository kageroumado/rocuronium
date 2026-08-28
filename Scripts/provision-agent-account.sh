#!/bin/bash
# Provision a dedicated agent account and strip it down to something worth running.
#
# The user-facing gesture is "enable agent session" plus a password; everything below is what
# that gesture has to do. Run as root — rocuronium invokes it behind a single authorization
# prompt. Idempotent: safe to re-run against an account that already exists.
#
# The password is read from stdin, never from argv, so it never reaches the process table or a
# shell history. `sysadminctl` only accepts one on argv or from a prompt, so it gets a pty.
#
# Usage: provision-agent-account.sh <shortname> [full name]
#        Run from a terminal it prompts for the password; piped, it reads it from stdin.
#
# What "stripped" means and why each piece is here:
#  - Onboarding is skipped by pre-seeding the keys Setup Assistant writes when a human clicks
#    through it. The key list is the authoritative one from the Setup Assistant binary, and the
#    values were read back from an account that had been through the flow on this OS version.
#  - The background suite (Spotlight, Siri, proactive/duet, Shortcuts) is what actually costs
#    ~3.1 W on an idle agent session, measured. None of it serves an agent.
#  - Reduced motion and a static wallpaper exist because an agent session renders for nobody —
#    every animated pixel is waste, and the aerial wallpaper extension alone held 241 MB.

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <shortname> [full name]" >&2; exit 1; }

NAME="$1"
FULL="${2:-Agent}"
OS_VERSION="$(sw_vers -productVersion)"
BUILD_VERSION="$(sw_vers -buildVersion)"

# The password never goes on argv, because argv is world-readable through `ps`. Prompted when
# run from a terminal, otherwise read from stdin.
#
# Creating an account needs root and nothing more. Only *changing* an existing account's password
# needs an admin credential, because that path demands a SecureToken unlock and fails with
# "Operation is not permitted without secure token unlock" — so this script provisions new
# accounts and never repairs one whose password is wrong. Use a fresh name instead.
if [ -t 0 ]; then
    read -r -s -p "Password for the new agent account: " PASSWORD; echo
else
    IFS= read -r PASSWORD || true
fi

# ---------------------------------------------------------------- account

if ! dscl . -read "/Users/$NAME" >/dev/null 2>&1; then
    [ -n "$PASSWORD" ] || { echo "no password on stdin and the account does not exist" >&2; exit 1; }
    echo "==> creating $NAME (standard user)"
    # Deliberately not -admin: the two service ACLs below are the whole access model, and an
    # admin account would bypass them while gaining far more than an agent needs.
    #
    # sysadminctl takes a password on argv or from an interactive prompt, and argv on macOS is
    # world-readable through `ps`. So it gets a pty instead, with the secret handed to expect
    # through the environment — which, for a root process, other users cannot read.
    # Match the prompt exactly. A loose pattern such as "(?i)password.*:" also matches
    # sysadminctl's own warning line about clear-text passwords, whose text contains "password"
    # and which precedes the real prompt — the secret is then sent into the log stream and the
    # account is created with no password at all, silently.
    AGENT_PW="$PASSWORD" expect -c '
        set timeout 60
        log_user 0
        spawn -noecho sysadminctl -addUser [lindex $argv 0] -fullName [lindex $argv 1] -password -
        expect {
            "User password:" { send "$env(AGENT_PW)\r"; exp_continue }
            eof
        }
    ' "$NAME" "$FULL" >/dev/null 2>&1 || true

    dscl . -read "/Users/$NAME" >/dev/null 2>&1 ||
        { echo "account creation failed" >&2; exit 1; }

    # A record with an unusable password is the failure mode the prompt-matching bug produced,
    # and it cannot be repaired here (SecureToken, above). Fail loudly rather than hand back an
    # account that cannot log in.
    AGENT_PW="$PASSWORD" expect -c '
        set timeout 20
        log_user 0
        spawn -noecho dscl . -authonly [lindex $argv 0]
        expect { "Password:" { send "$env(AGENT_PW)\r"; exp_continue } eof }
    ' "$NAME" >/dev/null 2>&1 ||
        { echo "created $NAME but its password does not authenticate — delete it and retry with a fresh name" >&2; exit 1; }
    echo "    credential verified"
else
    echo "==> $NAME already exists"
fi

UID_N="$(dscl . -read "/Users/$NAME" UniqueID | awk '{print $2}')"
HOME_DIR="$(dscl . -read "/Users/$NAME" NFSHomeDirectory | awk '{print $2}')"
[ -d "$HOME_DIR" ] || createhomedir -c -u "$NAME" >/dev/null

echo "==> uid $UID_N, home $HOME_DIR"

# ---------------------------------------------------------------- services

# Both ACLs, or authentication fails in a way that looks exactly like a wrong password: macOS
# validates the password first and the service ACL second.
echo "==> service ACLs"
dseditgroup -o edit -a "$NAME" -t user com.apple.access_screensharing 2>/dev/null || true
dseditgroup -o edit -a "$NAME" -t user com.apple.access_ssh 2>/dev/null || true

echo "==> enabling Screen Sharing and Remote Login"
launchctl enable system/com.apple.screensharing 2>/dev/null || true
launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true
systemsetup -setremotelogin on >/dev/null 2>&1 || true

# ---------------------------------------------------------------- preferences

# Written as the user so cfprefsd owns them correctly even though nobody is logged in.
asuser() { sudo -u "$NAME" "$@"; }

echo "==> skipping first-login onboarding"
# Every DidSee* key Setup Assistant knows about, marked seen. Anything left unset is a pane the
# assistant will stop on at first login, which is exactly the hang this is here to prevent.
for key in DidSeeAccessibility DidSeeActivationLock DidSeeAppearanceSetup DidSeeApplePaySetup \
           DidSeeAppStore DidSeeCloudSetup DidSeeiCloudLoginForStorageServices \
           DidSeeLockdownMode DidSeePrivacy DidSeeScreenTime DidSeeSiriSetup DidSeeSyncSetup \
           DidSeeSyncSetup2 DidSeeTermsOfAddress DidSeeTouchIDSetup; do
    asuser defaults write com.apple.SetupAssistant "$key" -bool true
done
for key in LastSeenAgeRangeSelectionProductVersion LastSeenCloudProductVersion \
           LastSeenDiagnosticsProductVersion LastSeeniCloudStorageServicesProductVersion \
           LastSeenIntelligenceProductVersion LastSeenSiriProductVersion \
           LastSeenSyncProductVersion; do
    asuser defaults write com.apple.SetupAssistant "$key" -string "$OS_VERSION"
done
asuser defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion -string "$BUILD_VERSION"
asuser defaults write com.apple.SetupAssistant MiniBuddyShouldLaunchToResumeSetup -bool false
asuser defaults write com.apple.SetupAssistant SkipFirstLoginOptimization -bool true
asuser defaults write com.apple.SetupAssistant SkipWallpaperAnimation -bool true

echo "==> disabling Siri and Apple Intelligence"
asuser defaults write com.apple.assistant.support "Assistant Enabled" -bool false
asuser defaults write com.apple.Siri StatusMenuVisible -bool false
asuser defaults write com.apple.Siri VoiceTriggerUserEnabled -bool false
asuser defaults write com.apple.Siri TypeToSiriEnabled -bool false

echo "==> disabling suggestions and proactive indexing"
asuser defaults write com.apple.lookup.shared LookupSuggestionsDisabled -bool true
asuser defaults write com.apple.suggestions SuggestionsAppLibraryEnabled -bool false
asuser defaults write com.apple.Spotlight showedFTE -bool true

echo "==> reduced motion and transparency (configuration profile)"
# These two cannot be set the way everything else here is, and the reason is worth stating
# because it looks like a bug twice over: `defaults write com.apple.universalaccess` fails with
# "Could not write domain" even as root (cfprefsd guards the domain behind an entitlement), and
# writing the plist directly into the account's home fails with "Operation not permitted" even as
# root (another user's ~/Library is TCC-protected, so the *caller* needs Full Disk Access, which
# root alone does not confer). A configuration profile is the supported channel — the same one
# MDM uses — and it needs one approval in System Settings rather than a password.
# A private directory rather than a fixed /tmp path: this script runs as root, and a predictable
# name in a world-writable directory lets any local user pre-create a symlink there and redirect
# root's write onto a file of their choosing.
PROFILE_DIR="$(mktemp -d -t agent-session)"
chmod 700 "$PROFILE_DIR"
PROFILE="$PROFILE_DIR/agent-session-accessibility.mobileconfig"
cat > "$PROFILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.apple.universalaccess</string>
      <key>PayloadIdentifier</key><string>glass.kagerou.agentsession.universalaccess</string>
      <key>PayloadUUID</key><string>$(uuidgen)</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadDisplayName</key><string>Agent session — reduced motion</string>
      <key>reduceMotion</key><true/>
      <key>reduceTransparency</key><true/>
    </dict>
  </array>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadIdentifier</key><string>glass.kagerou.agentsession</string>
  <key>PayloadUUID</key><string>$(uuidgen)</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadDisplayName</key><string>Agent session settings</string>
  <key>PayloadScope</key><string>User</string>
</dict>
</plist>
PLIST
chmod 600 "$PROFILE"
echo "    profile written to $PROFILE"
echo "    install it for $NAME with: profiles install -type=configuration -path=$PROFILE -user $NAME"

echo "==> stilling the desktop"
asuser defaults write com.apple.dock autohide -bool true
asuser defaults write com.apple.dock launchanim -bool false
asuser defaults write com.apple.dock expose-animation-duration -float 0
asuser defaults write com.apple.dock mineffect -string scale
asuser defaults write com.apple.finder DisableAllAnimations -bool true
asuser defaults write com.apple.finder CreateDesktop -bool false
asuser defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
asuser defaults write NSGlobalDomain NSScrollAnimationEnabled -bool false

echo "==> no screen saver, no display idle lock"
# The session has no seat and nobody watching; a screen saver is a renderer burning power for an
# audience of zero, and an idle lock would curtain the session out from under the agent.
asuser defaults -currentHost write com.apple.screensaver idleTime -int 0
asuser defaults write com.apple.screensaver askForPassword -bool false

echo "==> static wallpaper"
# The stock wallpaper is an animated aerial whose extension held 241 MB and rendered continuously
# for a desktop nobody watches. Deleting the store index does not help — "no index" resolves to
# the system default, which is the aerial — so a choice has to be written in explicitly.
#
# agent-wallpaper-black.plist is a captured wallpaper store index whose single choice is
# provider com.apple.wallpaper.choice.color with the configuration
# {type: systemColor, systemColor: {black: {}}} — no machine- or account-specific data in it.
# It is installed through `tee` running as the account, because a direct write into another
# user's ~/Library is refused even to root (TCC), while the account writing its own home is fine.
WP_TEMPLATE="$(dirname "$0")/agent-wallpaper-black.plist"
WP_STORE="$HOME_DIR/Library/Application Support/com.apple.wallpaper/Store"
if [ -f "$WP_TEMPLATE" ]; then
    asuser mkdir -p "$WP_STORE"
    asuser tee "$WP_STORE/Index.plist" < "$WP_TEMPLATE" >/dev/null && echo "    solid black" ||
        echo "    could not write the wallpaper store" >&2
else
    echo "    template missing at $WP_TEMPLATE" >&2
fi

chown -R "$NAME" "$HOME_DIR/Library/Preferences" 2>/dev/null || true

echo
echo "provisioned $NAME (uid $UID_N)."
echo "Remaining manual step: Accessibility for the controller, granted in that session once."
