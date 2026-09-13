#!/usr/bin/env bash
# Paramus targeted repair: Java 8 + GNOME-aware Display Guardian only.
# Revision 2: recognize the reviewed simpler Paramus Guardian (no custom modes).
# Run: sudo bash paramus-two-fixes.sh
# Inspect without changes: sudo bash paramus-two-fixes.sh --check
# Existing 6.1.1 installation required. No reboot or service restart is issued.
set -Eeuo pipefail
export LC_ALL=C
TARGET_USER=escapology
CHECK_ONLY=0
while (($#)); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --user) [[ $# -ge 2 ]] || { echo 'Missing --user value.' >&2; exit 2; }; TARGET_USER="$2"; shift 2 ;;
        --help|-h) sed -n '2,6p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
die() { echo "ERROR: $*" >&2; exit 1; }
section() { printf '\n%s\n' "$*"; }
[[ "$EUID" == 0 ]] || die 'Run with sudo (or as root through ScreenConnect).'
for command in getent id sha256sum awk grep sed readlink mktemp install cp mv ln \
               bash apt-get update-alternatives dpkg-query gdbus timeout xrandr pgrep \
               cmp chmod chown date flock; do
    command -v "$command" >/dev/null || die "Required command not installed: $command"
done
passwd_entry="$(getent passwd "$TARGET_USER")" || die "User does not exist: $TARGET_USER"
IFS=: read -r _ _ TARGET_UID TARGET_GID _ TARGET_HOME _ <<< "$passwd_entry"
[[ "$TARGET_UID" != 0 && "$TARGET_HOME" == /* && -d "$TARGET_HOME" ]] || die 'Expected a non-root game user with an existing home.'
guardian="$TARGET_HOME/.local/bin/escapology-display-guardian.sh"
unit_dir="$TARGET_HOME/.config/systemd/user"
service="$unit_dir/escapology-display-guardian.service"
autostart="$TARGET_HOME/.config/autostart/escapology-display-guardian.desktop"
dropin_dir="$service.d"
dropin="$dropin_dir/99-paramus-settle.conf"
wants="$unit_dir/default.target.wants"
enabled_link="$wants/escapology-display-guardian.service"
config=/etc/escapology-display.conf
for file in "$guardian" "$service" "$autostart" "$config"; do
    [[ -f "$file" && ! -L "$file" ]] || die "Expected a regular existing file: $file"
done
[[ ! -L "$dropin_dir" && ! -L "$wants" ]] || die 'Unexpected symlink in Guardian service directories.'
[[ ! -e "$dropin" && ! -L "$dropin" ]] || [[ -f "$dropin" && ! -L "$dropin" ]] || die "Unexpected file: $dropin"
if [[ -e "$enabled_link" || -L "$enabled_link" ]]; then
    [[ -L "$enabled_link" && "$(readlink -f "$enabled_link")" == "$(readlink -f "$service")" ]] || die 'Unexpected existing Guardian enable link; no changes made.'
fi
guardian_hash="$(sha256sum "$guardian" | awk '{print $1}')"
guardian_variant=standard
expected_guardian_hash='bc387372c8b4a680be929ec811f8ec8a5664026802896303e01334b7df764c38'
case "$guardian_hash" in
    d27574ed779cc71a07b462ee79baf03e29d1c9a5a5ad87fe20af58927bd48d3d|bc387372c8b4a680be929ec811f8ec8a5664026802896303e01334b7df764c38) ;;
    df437bf26472f79da43d9f2f74f4dab1b9f1ddc2b3792b7f7945af51d81c92e1) guardian_variant=paramus; expected_guardian_hash='df437bf26472f79da43d9f2f74f4dab1b9f1ddc2b3792b7f7945af51d81c92e1' ;;
    *)
        normalized_hash="$(awk '{sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); if ($0 != "" && $0 !~ /^#/) print}' "$guardian" | sha256sum | awk '{print $1}')"
        if [[ "$normalized_hash" == 'f54e271d9f69a1dc9d7277c671d6ec84192a51d46d09ac4077d47b94d9bfa927' ]]; then
            guardian_variant=paramus
            expected_guardian_hash='df437bf26472f79da43d9f2f74f4dab1b9f1ddc2b3792b7f7945af51d81c92e1'
        else
            die 'Guardian differs from the reviewed versions. No changes made; review that PC’s Guardian before patching.'
        fi ;;
esac
grep -Fxq "ExecStart=$guardian" "$service" || die 'Unexpected Guardian ExecStart; no changes made.'
grep -Eq '^Exec=.*systemctl --user (restart|start) escapology-display-guardian\.service' "$autostart" || die 'Unexpected Guardian autostart command; no changes made.'
# Keep existing unit/drop-ins rather than replace site-specific configuration.
# Refuse competing executable overrides that could bypass the readiness gate.
for file in "$dropin_dir"/*.conf; do
    [[ -f "$file" ]] || continue
    if grep -Eq '^[[:space:]]*(ExecStart|ExecStartPre|ExecStartPost)[[:space:]]*=' "$file"; then
        die "Guardian command override requires review: $file (no changes made)."
    fi
done
section "Paramus repair preflight: $TARGET_USER"
echo "Guardian recognized: $guardian"
echo "Guardian variant: $guardian_variant (repair revision 2)"
echo "Preserving display settings: $config"
echo 'Changes: full Java 8/default Java selection, Guardian runtime, autostart trigger, Guardian retry interval and login enable link.'
echo 'No game.sh, drivers, Firefox, audio, GNOME settings or ScreenConnect client replacement.'
echo 'No service restart, logout or reboot. Activate the fixes with a planned reboot.'
if ((CHECK_ONLY)); then
    echo 'CHECK ONLY PASSED. No files or packages changed. Java package availability is verified during installation.'
    exit 0
fi

exec 9>/run/lock/escapology-paramus-fix.lock
flock -n 9 || die 'Another Paramus repair is already running.'
backup_root=/var/backups/escapology-paramus
install -d -m 0700 "$backup_root"
backup="$(mktemp -d "$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
chmod 0700 "$backup"
cp -a "$guardian" "$backup/guardian.sh"
cp -a "$service" "$backup/guardian.service"
cp -a "$autostart" "$backup/guardian.desktop"
cp -a "$config" "$backup/escapology-display.conf"
if [[ -f "$dropin" ]]; then cp -a "$dropin" "$backup/99-paramus-settle.conf"; fi
if [[ -L "$enabled_link" ]]; then cp -a "$enabled_link" "$backup/enabled-link"; fi
update-alternatives --query java > "$backup/java-alternatives-before.txt" 2>&1 || true
printf 'User: %s\nHome: %s\nGuardian: %s\n' "$TARGET_USER" "$TARGET_HOME" "$guardian" > "$backup/paths.txt"
echo "Backup: $backup"

# Prepare and validate every replacement before installing anything.
stage="$backup/staged"
install -d -m 0700 "$stage"
if [[ "$guardian_variant" == paramus ]]; then
cat > "$stage/guardian.sh" <<'PARAMUS_FIELD_GUARDIAN'
#!/usr/bin/env bash
set -u

CONFIG_FILE="/etc/escapology-display.conf"
STATE_DIR="$HOME/.local/state/escapology"
LOG_FILE="$STATE_DIR/display-guardian.log"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

read_mode() {
	local requested="normal"

	if [[ -r "$CONFIG_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$CONFIG_FILE"
		requested="${DISPLAY_MODE:-normal}"
	fi

	case "$requested" in
		normal|left|right|inverted) printf '%s\n' "$requested" ;;
		*) printf '%s\n' normal ;;
	esac
}


# GNOME Shell contains Mutter. Bind to this user's real X11 session rather
# than the service's historical DISPLAY=:0 default. A missing/unresponsive
# compositor is a reason to wait, never a reason to force a modeset.
export LC_ALL=C
for required in gdbus timeout xrandr pgrep awk; do
	command -v "$required" >/dev/null 2>&1 || {
		log "Missing required command: $required; refusing to change displays."
		exit 1
	}
done
probe_session() {
	local pid item display_value="" auth_value="" session_type="" bus_value=""
	pid="$(pgrep -u "$(id -u)" -n -x gnome-shell)" || return 1
	[[ -r "/proc/$pid/environ" ]] || return 1
	while IFS= read -r -d '' item; do
		case "$item" in
			DISPLAY=*) display_value="${item#*=}" ;;
			XAUTHORITY=*) auth_value="${item#*=}" ;;
			XDG_SESSION_TYPE=*) session_type="${item#*=}" ;;
			DBUS_SESSION_BUS_ADDRESS=*) bus_value="${item#*=}" ;;
		esac
	done < "/proc/$pid/environ"
	[[ "$session_type" != "wayland" && -n "$display_value" ]] || return 1
	export DISPLAY="$display_value"
	if [[ -n "$auth_value" ]]; then export XAUTHORITY="$auth_value"; else unset XAUTHORITY; fi
	[[ -z "$bus_value" ]] || export DBUS_SESSION_BUS_ADDRESS="$bus_value"
	timeout 5 gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
		--object-path /org/gnome/Mutter/DisplayConfig \
		--method org.gnome.Mutter.DisplayConfig.GetCurrentState >/dev/null 2>&1 || return 1
	snapshot="$(timeout 5 xrandr --query 2>/dev/null)" || return 1
	[[ "$snapshot" == *" connected"* ]] || return 1
	session_key="$pid/$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)/$DISPLAY/${XAUTHORITY:-}"
}

# Parse the active mode/rate and the rotation BEFORE the supported-rotations
# parenthesis. The words inside '(normal left inverted right ...)' describe
# capabilities, not the current rotation.
layout_is_correct() {
	local output="$1" rotation="$2" desired="$3" geometry="$4"
	awk -v out="$output" -v rot="$rotation" -v desired="$desired" -v geom="$geometry" '
		/^Screen / {
			for(i=1;i<=NF;i++) if($i=="current") {
				height=$(i+3); sub(/,/,"",height); framebuffer=$(i+1) "x" height
			}
		}
		$2 == "connected" || $2 == "disconnected" {
			if($2=="connected") connected++
			inside=($1 == out && $2 == "connected")
			if (inside) {
				line=$0; sub(/ \(.*/, "", line)
				n=split(line,a," "); actual="normal"
				for(i=1;i<=n;i++) {
					if(a[i]=="primary") primary=1
					if(a[i]==geom "+0+0") geometry_ok=1
					if(a[i]=="left" || a[i]=="right" || a[i]=="inverted") actual=a[i]
				}
				rotation_ok=(actual==rot)
			}
			next
		}
		inside && $1 == desired {
			for(i=2;i<=NF;i++) if($i ~ /\*/) {
				active=1; rate=$i+0; rate_ok=(rate>=59.8 && rate<=60.2)
			}
		}
		END {exit !(primary && geometry_ok && rotation_ok && active && rate_ok &&
		            (connected>1 || framebuffer==geom))}
	' <<< "$snapshot"
}

apply_layout() {
	local mode output desired_mode geometry request connected
	local -a framebuffer=()
	mode="$(read_mode)"
	request="$mode"
	[[ "${last_layout_request:-}" != "$request" ||
	   "${last_layout_snapshot:-}" != "$snapshot" ]] || return 0
	output="$(awk '$2=="connected" && $3=="primary" {print $1; exit}' <<< "$snapshot")"
	connected="$(awk '$2=="connected" {n++} END {print n+0}' <<< "$snapshot")"
	if [[ -z "$output" ]]; then
		# With several connected monitors and no primary, there is no safe way
		# to infer which is the game display. Wait for an unambiguous selection.
		[[ "$connected" == 1 ]] || return 1
		output="$(awk '$2=="connected" {print $1; exit}' <<< "$snapshot")"
	fi
	case "$mode" in
		left|right) geometry="1080x1920" ;;
		*) geometry="1920x1080" ;;
	esac
	desired_mode="1920x1080"
	if layout_is_correct "$output" "$mode" "$desired_mode" "$geometry"; then
		last_layout_request="$request"
		last_layout_snapshot="$snapshot"
		return 0
	fi
	# Cool down failures as well as successful changes; do not hammer Mutter.
	(( SECONDS >= next_attempt )) || return 1
	next_attempt=$((SECONDS + 30))
	# Preserve the original single-display framebuffer behavior without
	# shrinking the desktop around other attached monitors.
	[[ "$connected" != 1 ]] || framebuffer=(--fb "$geometry")
	if timeout 10 xrandr "${framebuffer[@]}" --output "$output" --primary \
		--mode "$desired_mode" --rate 60 --pos 0x0 --rotate "$mode" 2>>"$LOG_FILE"; then
		:
	elif timeout 10 xrandr "${framebuffer[@]}" --output "$output" --primary \
		--mode "$desired_mode" --pos 0x0 --rotate "$mode" 2>>"$LOG_FILE"; then
		:
	elif timeout 10 xrandr --output "$output" --primary --auto --pos 0x0 \
		--rotate "$mode" 2>>"$LOG_FILE"; then
		:
	else
		log "Display change failed for $output; retrying no sooner than 30 seconds."
		next_attempt=$((SECONDS + 30))
		return 1
	fi
	log "Applied output=$output rotation=$mode requested_mode=$desired_mode"
	# Remember successful fallback states too; a monitor without 1080p/60
	# must not cause a repeated configuration loop.
	last_layout_snapshot="$(timeout 5 xrandr --query 2>/dev/null)" || { last_layout_snapshot=""; return 1; }
	last_layout_request="$request"
}

session_key=""
previous_session=""
previous_snapshot=""
session_since=$SECONDS
stable_since=$SECONDS
next_attempt=0
last_layout_snapshot=""
last_layout_request=""
while true; do
	if ! probe_session; then
		previous_session=""
		previous_snapshot=""
		last_layout_snapshot=""
		sleep 5
		continue
	fi
	if [[ "$session_key" != "$previous_session" ]]; then
		previous_session="$session_key"
		previous_snapshot=""
		session_since=$SECONDS
		last_layout_snapshot=""
		log "GNOME/Mutter is responding; waiting at least 20 seconds for startup to settle."
	fi
	if [[ "$snapshot" != "$previous_snapshot" ]]; then
		previous_snapshot="$snapshot"
		stable_since=$SECONDS
	fi
	# Require 20 seconds after session readiness and 10 seconds of unchanged
	# display state. Recheck these conditions after login/restart/hotplug.
	if (( SECONDS - session_since >= 20 && SECONDS - stable_since >= 10 )); then
		apply_layout || true
	fi
	sleep 5
done

PARAMUS_FIELD_GUARDIAN
else
cat > "$stage/guardian.sh" <<'PARAMUS_GUARDIAN'
#!/usr/bin/env bash
set -u

CONFIG_FILE="/etc/escapology-display.conf"
STATE_DIR="$HOME/.local/state/escapology"
LOG_FILE="$STATE_DIR/display-guardian.log"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

read_mode() {
	local requested="normal"

	if [[ -r "$CONFIG_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$CONFIG_FILE"
		requested="${DISPLAY_MODE:-normal}"
	fi

	case "$requested" in
		normal|left|right|inverted) printf '%s\n' "$requested" ;;
		*) printf '%s\n' normal ;;
	esac
}


read_force_1080p() {
	local requested="0"
	local game_name=""

	if [[ -r "$CONFIG_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$CONFIG_FILE" 2>/dev/null || true
		requested="${FORCE_1080P:-0}"
		game_name="${GAME_NAME:-}"
	fi

	if [[ "$requested" == "1" || "$game_name" == "star-trek" || "$game_name" == "startrek" ]]; then
		printf '%s\n' 1
	else
		printf '%s\n' 0
	fi
}

output_has_mode() {
	local output="$1"
	local wanted="$2"

	timeout 5 xrandr --query 2>/dev/null | awk -v out="$output" -v wanted="$wanted" '
		$1 == out && $2 == "connected" {inside=1; next}
		inside && $1 ~ /^[0-9]/ {
			if ($1 == wanted) found=1
			next
		}
		inside && $1 !~ /^[0-9]/ {inside=0}
		END {exit !found}
	'
}

ensure_1080p_mode() {
	local output="$1"
	local force_1080p
	local custom_mode="1920x1080_esc60"

	force_1080p="$(read_force_1080p)"

	if output_has_mode "$output" "1920x1080"; then
		printf '%s\n' '1920x1080'
		return 0
	fi

	if [[ "$force_1080p" != "1" ]]; then
		printf '%s\n' '1920x1080'
		return 0
	fi

	if output_has_mode "$output" "$custom_mode"; then
		printf '%s\n' "$custom_mode"
		return 0
	fi

	# Startrek field fix: the HDMI extender EDID exposes 1920x1080 to DRM/i915
	# but XRandR can omit it. Create a standard CEA 1080p60 mode and attach it
	# to the actual connected output. Never fail the guardian because of this.
	timeout 5 xrandr --newmode "$custom_mode" 148.50 \
		1920 2008 2052 2200 \
		1080 1084 1089 1125 \
		+HSync +VSync 2>>"$LOG_FILE" || true
	timeout 5 xrandr --addmode "$output" "$custom_mode" 2>>"$LOG_FILE" || true

	if output_has_mode "$output" "$custom_mode"; then
		printf '%s\n' "$custom_mode"
	else
		printf '%s\n' '1920x1080'
	fi
}

# GNOME Shell contains Mutter. Bind to this user's real X11 session rather
# than the service's historical DISPLAY=:0 default. A missing/unresponsive
# compositor is a reason to wait, never a reason to force a modeset.
export LC_ALL=C
for required in gdbus timeout xrandr pgrep awk; do
	command -v "$required" >/dev/null 2>&1 || {
		log "Missing required command: $required; refusing to change displays."
		exit 1
	}
done
probe_session() {
	local pid item display_value="" auth_value="" session_type="" bus_value=""
	pid="$(pgrep -u "$(id -u)" -n -x gnome-shell)" || return 1
	[[ -r "/proc/$pid/environ" ]] || return 1
	while IFS= read -r -d '' item; do
		case "$item" in
			DISPLAY=*) display_value="${item#*=}" ;;
			XAUTHORITY=*) auth_value="${item#*=}" ;;
			XDG_SESSION_TYPE=*) session_type="${item#*=}" ;;
			DBUS_SESSION_BUS_ADDRESS=*) bus_value="${item#*=}" ;;
		esac
	done < "/proc/$pid/environ"
	[[ "$session_type" != "wayland" && -n "$display_value" ]] || return 1
	export DISPLAY="$display_value"
	if [[ -n "$auth_value" ]]; then export XAUTHORITY="$auth_value"; else unset XAUTHORITY; fi
	[[ -z "$bus_value" ]] || export DBUS_SESSION_BUS_ADDRESS="$bus_value"
	timeout 5 gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
		--object-path /org/gnome/Mutter/DisplayConfig \
		--method org.gnome.Mutter.DisplayConfig.GetCurrentState >/dev/null 2>&1 || return 1
	snapshot="$(timeout 5 xrandr --query 2>/dev/null)" || return 1
	[[ "$snapshot" == *" connected"* ]] || return 1
	session_key="$pid/$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)/$DISPLAY/${XAUTHORITY:-}"
}

# Parse the active mode/rate and the rotation BEFORE the supported-rotations
# parenthesis. The words inside '(normal left inverted right ...)' describe
# capabilities, not the current rotation.
layout_is_correct() {
	local output="$1" rotation="$2" desired="$3" geometry="$4"
	awk -v out="$output" -v rot="$rotation" -v desired="$desired" -v geom="$geometry" '
		/^Screen / {
			for(i=1;i<=NF;i++) if($i=="current") {
				height=$(i+3); sub(/,/,"",height); framebuffer=$(i+1) "x" height
			}
		}
		$2 == "connected" || $2 == "disconnected" {
			if($2=="connected") connected++
			inside=($1 == out && $2 == "connected")
			if (inside) {
				line=$0; sub(/ \(.*/, "", line)
				n=split(line,a," "); actual="normal"
				for(i=1;i<=n;i++) {
					if(a[i]=="primary") primary=1
					if(a[i]==geom "+0+0") geometry_ok=1
					if(a[i]=="left" || a[i]=="right" || a[i]=="inverted") actual=a[i]
				}
				rotation_ok=(actual==rot)
			}
			next
		}
		inside && $1 == desired {
			for(i=2;i<=NF;i++) if($i ~ /\*/) {
				active=1; rate=$i+0; rate_ok=(rate>=59.8 && rate<=60.2)
			}
		}
		END {exit !(primary && geometry_ok && rotation_ok && active && rate_ok &&
		            (connected>1 || framebuffer==geom))}
	' <<< "$snapshot"
}

apply_layout() {
	local mode output desired_mode geometry request connected
	local -a framebuffer=()
	mode="$(read_mode)"
	request="$mode/$(read_force_1080p)"
	[[ "${last_layout_request:-}" != "$request" ||
	   "${last_layout_snapshot:-}" != "$snapshot" ]] || return 0
	output="$(awk '$2=="connected" && $3=="primary" {print $1; exit}' <<< "$snapshot")"
	connected="$(awk '$2=="connected" {n++} END {print n+0}' <<< "$snapshot")"
	if [[ -z "$output" ]]; then
		# With several connected monitors and no primary, there is no safe way
		# to infer which is the game display. Wait for an unambiguous selection.
		[[ "$connected" == 1 ]] || return 1
		output="$(awk '$2=="connected" {print $1; exit}' <<< "$snapshot")"
	fi
	case "$mode" in
		left|right) geometry="1080x1920" ;;
		*) geometry="1920x1080" ;;
	esac
	desired_mode="1920x1080"
	if ! output_has_mode "$output" "$desired_mode" && [[ "$(read_force_1080p)" == 1 ]]; then
		desired_mode="1920x1080_esc60"
	fi
	if layout_is_correct "$output" "$mode" "$desired_mode" "$geometry"; then
		last_layout_request="$request"
		last_layout_snapshot="$snapshot"
		return 0
	fi
	# Cool down failures as well as successful changes; do not hammer Mutter.
	(( SECONDS >= next_attempt )) || return 1
	next_attempt=$((SECONDS + 30))
	desired_mode="$(ensure_1080p_mode "$output")"
	# Preserve the original single-display framebuffer behavior without
	# shrinking the desktop around other attached monitors.
	[[ "$connected" != 1 ]] || framebuffer=(--fb "$geometry")
	if timeout 10 xrandr "${framebuffer[@]}" --output "$output" --primary \
		--mode "$desired_mode" --rate 60 --pos 0x0 --rotate "$mode" 2>>"$LOG_FILE"; then
		:
	elif timeout 10 xrandr "${framebuffer[@]}" --output "$output" --primary \
		--mode "$desired_mode" --pos 0x0 --rotate "$mode" 2>>"$LOG_FILE"; then
		:
	elif timeout 10 xrandr --output "$output" --primary --auto --pos 0x0 \
		--rotate "$mode" 2>>"$LOG_FILE"; then
		:
	else
		log "Display change failed for $output; retrying no sooner than 30 seconds."
		next_attempt=$((SECONDS + 30))
		return 1
	fi
	log "Applied output=$output rotation=$mode requested_mode=$desired_mode"
	# Remember successful fallback states too; a monitor without 1080p/60
	# must not cause a repeated configuration loop.
	last_layout_snapshot="$(timeout 5 xrandr --query 2>/dev/null)" || { last_layout_snapshot=""; return 1; }
	last_layout_request="$request"
}

session_key=""
previous_session=""
previous_snapshot=""
session_since=$SECONDS
stable_since=$SECONDS
next_attempt=0
last_layout_snapshot=""
last_layout_request=""
while true; do
	if ! probe_session; then
		previous_session=""
		previous_snapshot=""
		last_layout_snapshot=""
		sleep 5
		continue
	fi
	if [[ "$session_key" != "$previous_session" ]]; then
		previous_session="$session_key"
		previous_snapshot=""
		session_since=$SECONDS
		last_layout_snapshot=""
		log "GNOME/Mutter is responding; waiting at least 20 seconds for startup to settle."
	fi
	if [[ "$snapshot" != "$previous_snapshot" ]]; then
		previous_snapshot="$snapshot"
		stable_since=$SECONDS
	fi
	# Require 20 seconds after session readiness and 10 seconds of unchanged
	# display state. Recheck these conditions after login/restart/hotplug.
	if (( SECONDS - session_since >= 20 && SECONDS - stable_since >= 10 )); then
		apply_layout || true
	fi
	sleep 5
done

PARAMUS_GUARDIAN
fi
bash -n "$stage/guardian.sh"
sed 's/systemctl --user restart escapology-display-guardian\.service/systemctl --user start escapology-display-guardian.service/g' \
    "$autostart" > "$stage/guardian.desktop"
printf '[Service]\nRestartSec=10\n' > "$stage/99-paramus-settle.conf"

# Java 8 field fix (2026-09-12). Install the graphical runtime, even when
# ScreenConnect is already present. Do not remove/reinstall remote clients.
ensure_screenconnect_java8() {
	section "SCREENCONNECT JAVA 8 RUNTIME"
	local java8="" candidate version="" previous=""
	JAVA8_STATUS="WARNING: Java 8 repair was not completed."
	if ! apt-get -o Acquire::Retries=3 --no-remove install -y openjdk-8-jre; then
		echo "$JAVA8_STATUS Full openjdk-8-jre could not be installed from the configured repositories."
		return 0
	fi
	# Query registered alternatives, so this works across CPU architectures.
	while IFS= read -r candidate; do
		[[ "$candidate" == */java-8-openjdk-*/jre/bin/java ||
		   "$candidate" == */java-8-openjdk-*/bin/java ]] || continue
		[[ -x "$candidate" ]] || continue
		version="$("$candidate" -version 2>&1)" || continue
		if [[ "$version" == *'version "1.8.'* ]]; then
			java8="$candidate"
			break
		fi
	done < <(update-alternatives --list java 2>/dev/null || true)
	if [[ -z "$java8" ]]; then
		echo "$JAVA8_STATUS No working registered OpenJDK 8 executable was found."
		return 0
	fi
	previous="$(readlink -f /usr/bin/java 2>/dev/null || true)"
	if ! update-alternatives --set java "$java8"; then
		echo "$JAVA8_STATUS Could not select Java 8 as the system default."
		return 0
	fi
	version="$(/usr/bin/java -version 2>&1)" || version=""
	if [[ "$version" != *'version "1.8.'* ]]; then
		echo "$JAVA8_STATUS The system Java command did not verify as Java 8."
		return 0
	fi
	JAVA8_STATUS="Full Java 8 installed and selected as the system default."
	echo "$JAVA8_STATUS Previous Java: ${previous:-unknown}"
	echo "$version"
	echo "Running ScreenConnect processes use this after reboot (or a later ScreenConnect restart)."
	echo "Clients configured with their own explicit Java path require separate verification."
}

ensure_screenconnect_java8

# Use rename, not truncation: a running Guardian retains its old open file
# until the planned reboot and cannot read a half-written replacement.
atomic_install() {
    local source="$1" target="$2" mode="$3" temporary
    temporary="$(mktemp "${target}.paramus-XXXXXX")" || return 1
    if ! install -m "$mode" -o "$TARGET_UID" -g "$TARGET_GID" "$source" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -fT -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        return 1
    fi
}
install -d -o "$TARGET_UID" -g "$TARGET_GID" -m 0755 "$dropin_dir" "$wants"
atomic_install "$stage/guardian.sh" "$guardian" 0755
atomic_install "$stage/guardian.desktop" "$autostart" 0644
atomic_install "$stage/99-paramus-settle.conf" "$dropin" 0644
if [[ ! -L "$enabled_link" ]]; then
    ln -s ../escapology-display-guardian.service "$enabled_link"
    chown -h "$TARGET_UID:$TARGET_GID" "$enabled_link"
fi
[[ "$(sha256sum "$guardian" | awk '{print $1}')" == "$expected_guardian_hash" ]] || die "Guardian verification failed. Backup: $backup"
cmp -s "$config" "$backup/escapology-display.conf" || die "Display configuration changed during repair; investigate. Backup: $backup"
section 'PARAMUS REPAIR STAGED'
echo 'Guardian repair installed and enabled for future logins.'
echo "Java: $JAVA8_STATUS"
echo "Backup: $backup"
echo 'Reboot this PC during downtime to activate both changes. This script has not restarted any service.'
if [[ "$JAVA8_STATUS" != 'Full Java 8 installed and selected as the system default.' ]]; then
    echo 'PARTIAL REPAIR: Guardian is staged, but Java 8 still needs attention. Rerunning this script is supported.' >&2
    exit 1
fi
echo 'Both fixes are staged. Verify the display and ScreenConnect after the planned reboot.'
