import Foundation

/// Compiled into the app, rather than executed from a replaceable resource in a
/// user-writable app bundle. Only system utilities and an exact pinned helper run
/// with administrator privileges. Never invoke this script during normal tests.
public enum LocalFanInstallerScript {
    public static let source = #"""
set -eu
umask 077
action="$1"; approved_uid="$2"; source_app="$3"; approved_app_hash="$4"; approved_helper_hash="$5"; generation="$6"
base='/Library/Application Support/MacToolbox/FanControl'
label='local.mactoolbox.fan-local'
plist='/Library/LaunchDaemons/local.mactoolbox.fan-local.plist'
config="$base/authorization.plist"
die() { printf '%s\n' "$1" >&2; exit 1; }
hash_ok() { [ "${#1}" -eq 40 ] && case "$1" in *[!0-9a-f]*) return 1;; *) return 0;; esac; }
uuid_ok() { printf '%s' "$1" | /usr/bin/grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
root_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f '%u' "$1")" = 0 ] &&
  [ $((0$(/usr/bin/stat -f '%Lp' "$1") & 022)) -eq 0 ] || die "Unsafe service directory: $1"
  [ "$(/bin/ls -lde "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] || die "Extended ACL on service directory: $1"
}
root_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f '%u' "$1")" = 0 ] &&
  [ "$(/usr/bin/stat -f '%l' "$1")" = 1 ] &&
  [ $((0$(/usr/bin/stat -f '%Lp' "$1") & 022)) -eq 0 ] || die "Unsafe service file: $1"
  [ "$(/bin/ls -lde "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] || die "Extended ACL on service file: $1"
}
ensure_dir() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then /bin/mkdir -m 755 "$1"; /bin/chmod -N "$1"; fi; root_dir "$1"; }
no_symlink_components() {
  part="$1"
  while [ "$part" != / ]; do [ ! -L "$part" ] || die 'Application path contains a symbolic link'; part=$(/usr/bin/dirname "$part"); done
}
read_field() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }
verify_code() { /usr/bin/codesign --verify --strict --all-architectures -R="identifier \"$2\" and cdhash H\"$3\"" "$1"; }
[ "$(/usr/bin/id -u)" = 0 ] || die 'Administrator approval is required'
case "$action" in install|uninstall) ;; *) die 'Invalid service action';; esac
case "$approved_uid" in ''|*[!0-9]*) die 'Invalid user';; esac
[ "$approved_uid" -gt 0 ] && [ "$approved_uid" -le 2147483647 ] || die 'Invalid user'
hash_ok "$approved_app_hash" && hash_ok "$approved_helper_hash" && uuid_ok "$generation" || die 'Invalid build identity'
case "$source_app" in /Users/*/Applications/'Mac Go.app'|/Users/*/Applications/'Mac 工具箱.app') ;; *) die 'Unexpected application location';; esac
case "$source_app" in *'/../'*|*'/./'*|*'//'*) die 'Noncanonical application path';; esac
if printf '%s' "$source_app" | /usr/bin/grep -q '[[:cntrl:]]'; then die 'Invalid application path'; fi
no_symlink_components "$source_app"
[ -d "$source_app" ] && [ "$(/usr/bin/stat -f '%u' "$source_app")" = "$approved_uid" ] || die 'Application owner differs from approved user'
verify_code "$source_app" 'local.mactoolbox.app' "$approved_app_hash"
/usr/bin/codesign --verify --deep --strict "$source_app"
source_helper="$source_app/Contents/MacOS/MacToolboxFanHelper"
[ -f "$source_helper" ] && [ ! -L "$source_helper" ] && [ "$(/usr/bin/stat -f '%l' "$source_helper")" = 1 ] || die 'Invalid bundled helper'
verify_code "$source_helper" 'local.mactoolbox.fan-helper' "$approved_helper_hash"
root_dir /Library; root_dir '/Library/Application Support'; root_dir /Library/LaunchDaemons
ensure_dir '/Library/Application Support/MacToolbox'
ensure_dir "$base"
lock="$base/.operation-lock"; lock_held=0; stage=''; created_generation=''
stopped=0; committed=0; success=0; old_generation=''; old_helper=''
had_config=0; had_plist=0
cleanup() {
  result=$?
  if [ "$success" = 0 ] && [ "$stopped" = 1 ]; then
    if [ "$committed" = 1 ]; then
      /bin/launchctl bootout "system/$label" >/dev/null 2>&1 || true
      if [ "$had_config" = 1 ]; then /bin/cp -p "$stage/old-authorization.plist" "$base/.rollback.plist"; /bin/mv -f "$base/.rollback.plist" "$config"; else /bin/rm -f "$config"; fi
      if [ "$had_plist" = 1 ]; then /bin/cp -p "$stage/old-launch.plist" "/Library/LaunchDaemons/.$label.rollback"; /bin/mv -f "/Library/LaunchDaemons/.$label.rollback" "$plist"; else /bin/rm -f "$plist"; fi
    fi
    if [ "$had_plist" = 1 ]; then /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || true; fi
  fi
  if [ "$action" = install ] && [ "$success" = 0 ] && [ -n "$created_generation" ]; then
    /bin/rm -f "$created_generation/MacToolboxFanHelper" "$created_generation/authorization.plist"
    /bin/rmdir "$created_generation" 2>/dev/null || true
  fi
  # Only fixed files in the root-created staging directory are removed.
  if [ -n "$stage" ]; then
    /bin/rm -f "$stage/old-authorization.plist" "$stage/old-launch.plist" "$stage/authorization.plist" "$stage/launch.plist" "$stage/MacToolboxFanHelper"
    /bin/rmdir "$stage" 2>/dev/null || true
  fi
  if [ "$lock_held" = 1 ]; then /bin/rm -f "$lock/pid"; /bin/rmdir "$lock" 2>/dev/null || true; fi
  if [ "$action" = uninstall ] && [ "$success" = 1 ] && [ "$result" != 0 ]; then
    printf '%s\n' 'Service removed and stopped; some inactive backup files remain. No old service was restarted.' >&2
  fi
  exit "$result"
}
trap cleanup EXIT
if ! /bin/mkdir -m 700 "$lock" 2>/dev/null; then
  die 'Another operation or an interrupted operation lock exists. Do not remove it while an installer is running; administrator recovery is required.'
fi
lock_held=1
printf '%s\n' "$$" > "$lock/pid"
stage=$(/usr/bin/mktemp -d "$base/.install.XXXXXXXX")
if [ -e "$config" ] || [ -L "$config" ]; then
  root_file "$config"
  [ "$(read_field "$config" schemaVersion)" = 1 ] && [ "$(read_field "$config" ownerUID)" = "$approved_uid" ] || die 'A different user owns this service'
  old_generation=$(read_field "$config" generation); old_hash=$(read_field "$config" helperCDHash)
  uuid_ok "$old_generation" && hash_ok "$old_hash" || die 'Invalid old authorization'
  root_dir "$base/generation-$old_generation"
  old_helper="$base/generation-$old_generation/MacToolboxFanHelper"
  root_file "$old_helper"; verify_code "$old_helper" 'local.mactoolbox.fan-helper' "$old_hash"
  /bin/cp -p "$config" "$stage/old-authorization.plist"; had_config=1
fi
if [ -e "$plist" ] || [ -L "$plist" ]; then
  root_file "$plist"
  [ "$had_config" = 1 ] && [ "$(read_field "$plist" Label)" = "$label" ] &&
  [ "$(read_field "$plist" ProgramArguments.0)" = "$old_helper" ] || die 'Unexpected launch service configuration'
  /bin/cp -p "$plist" "$stage/old-launch.plist"; had_plist=1
fi
if /bin/launchctl print 'system/local.mactoolbox.fan-helper' >/dev/null 2>&1; then die 'Disable the Apple-signed fan service before using local mode'; fi
# Validate the copied executable before any root execution; swapping a source
# file after approval cannot replace this exact administrator-approved hash.
# Use the current helper for recovery checks as well as a new installation, so
# an old helper's startup failure cannot make an otherwise safe update impossible.
/bin/cp "$source_helper" "$stage/MacToolboxFanHelper"
/bin/chmod -N "$stage/MacToolboxFanHelper"
/usr/sbin/chown root:wheel "$stage/MacToolboxFanHelper"; /bin/chmod 755 "$stage/MacToolboxFanHelper"
root_file "$stage/MacToolboxFanHelper"; verify_code "$stage/MacToolboxFanHelper" 'local.mactoolbox.fan-helper' "$approved_helper_hash"
if [ "$action" = install ]; then
  /usr/bin/plutil -create xml1 "$stage/authorization.plist"
  /usr/bin/plutil -insert schemaVersion -integer 1 "$stage/authorization.plist"
  /usr/bin/plutil -insert ownerUID -integer "$approved_uid" "$stage/authorization.plist"
  /usr/bin/plutil -insert appCDHash -string "$approved_app_hash" "$stage/authorization.plist"
  /usr/bin/plutil -insert helperCDHash -string "$approved_helper_hash" "$stage/authorization.plist"
  /usr/bin/plutil -insert generation -string "$generation" "$stage/authorization.plist"
  /bin/chmod 644 "$stage/authorization.plist"
fi
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
  [ "$had_plist" = 1 ] || die 'An unmanaged service already uses this name'
  /bin/launchctl bootout "system/$label"
fi
stopped=1
attempt=0
while /bin/launchctl print "system/$label" >/dev/null 2>&1; do
  attempt=$((attempt + 1)); [ "$attempt" -le 40 ] || die 'Old service did not stop'
  /bin/sleep 0.25
done
# Restore a legacy journal with its validated helper before moving to the private
# runtime directory. Do not ignore recovery errors or delete an old journal.
legacy_state='/var/run/local.mactoolbox.fan-state.json'
if [ -e "$legacy_state" ] || [ -L "$legacy_state" ]; then
  [ -n "$old_helper" ] || die 'Legacy recovery state exists without a validated helper'
  "$old_helper" --restore-owned
fi
# The new helper also acquires any safe legacy lock before its new lock, waiting
# for an old process to finish restoring. No journal means no hardware writes.
"$stage/MacToolboxFanHelper" --restore-owned
if [ "$action" = uninstall ]; then
  [ "$had_config" = 1 ] || die 'Local service is not installed'
  # Validate every retained generation before removing any installed file.
  for directory in "$base"/generation-*; do
    [ -e "$directory" ] || continue
    root_dir "$directory"
    version_config="$directory/authorization.plist"; root_file "$version_config"
    version_generation=$(read_field "$version_config" generation); version_hash=$(read_field "$version_config" helperCDHash)
    uuid_ok "$version_generation" && hash_ok "$version_hash" && [ "$directory" = "$base/generation-$version_generation" ] || die 'Invalid retained generation'
    root_file "$directory/MacToolboxFanHelper"
    verify_code "$directory/MacToolboxFanHelper" 'local.mactoolbox.fan-helper' "$version_hash"
    [ "$(/bin/ls -A "$directory" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 2 ] || die 'Unexpected files in a service generation'
  done
  committed=1
  /bin/rm -f "$plist" "$config"
  # The service is now uninstalled. Cleanup is irreversible and must never
  # trigger rollback to a helper that may already have been removed.
  success=1
  for directory in "$base"/generation-*; do
    [ -e "$directory" ] || continue
    /bin/rm "$directory/MacToolboxFanHelper" "$directory/authorization.plist"
    /bin/rmdir "$directory"
  done
  printf '%s\n' 'Local fan service removed; owned fan state restored.'
  exit 0
fi
destination="$base/generation-$generation"
[ ! -e "$destination" ] && [ ! -L "$destination" ] || die 'Generation already exists'
/bin/mkdir -m 755 "$destination"
created_generation="$destination"
/bin/chmod -N "$destination"
/bin/mv "$stage/MacToolboxFanHelper" "$destination/MacToolboxFanHelper"
/bin/cp "$stage/authorization.plist" "$destination/authorization.plist"; /bin/chmod 644 "$destination/authorization.plist"
/usr/bin/plutil -create xml1 "$stage/launch.plist"
/usr/bin/plutil -insert Label -string "$label" "$stage/launch.plist"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$stage/launch.plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$destination/MacToolboxFanHelper" "$stage/launch.plist"
/usr/bin/plutil -insert ProgramArguments.1 -string '--local-daemon' "$stage/launch.plist"
/usr/bin/plutil -insert MachServices -json '{"local.mactoolbox.fan-local":true}' "$stage/launch.plist"
/usr/bin/plutil -insert RunAtLoad -bool YES "$stage/launch.plist"
/usr/bin/plutil -insert KeepAlive -bool YES "$stage/launch.plist"
/usr/bin/plutil -insert ProcessType -string Background "$stage/launch.plist"
/usr/bin/plutil -insert AssociatedBundleIdentifiers -json '["local.mactoolbox.app"]' "$stage/launch.plist"
/usr/bin/plutil -lint "$stage/launch.plist"
/bin/chmod 644 "$stage/launch.plist"
committed=1
/bin/mv "$stage/authorization.plist" "$config"
/usr/bin/install -o root -g wheel -m 644 "$stage/launch.plist" "/Library/LaunchDaemons/.$label.new"
/bin/chmod -N "/Library/LaunchDaemons/.$label.new"
/bin/mv -f "/Library/LaunchDaemons/.$label.new" "$plist"
/bin/launchctl bootstrap system "$plist"
/bin/launchctl print "system/$label" >/dev/null
success=1
printf '%s\n' 'Local fan service installed for this exact app build. Fan speed unchanged.'
"""#
}
