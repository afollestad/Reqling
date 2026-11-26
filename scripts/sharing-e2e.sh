#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: ./scripts/sharing-e2e.sh <command>

Runs iCloud sharing against real CloudKit between two Macs signed in to different Apple Accounts: this one, the
owner, and a participant reached over SSH, either a tart VM made here or another Mac.

  vm-setup [<restore image>]
             Installs tart if it's missing, creates the VM from a macOS 26 restore image, or the URL or file given (a
             20 GB download, deleted once the VM exists), and opens it to finish setting up by hand; see the checklist
             it prints.
  vm-start [--window]
             Starts the VM, without a window unless asked, as for clicking through a share's link by hand.
  vm-stop    Shuts the VM down.
  vm-delete  Asks first, since other projects may use the VM too, then unpairs it, and deletes it and anything tart
             has cached.
  pair --vm | pair <user@host>
             Records the participant, the VM or another Mac, copies an SSH key of this script's own to it (its
             password is asked once), checks it runs macOS 26 or later and is signed in to iCloud, and prints its
             Provisioning UDID for the profile. Another Mac needs Remote Login turned on first.
  launch     Builds the harness's copy of the app (`build.sh --e2e`), runs it here as the owner and on the participant,
             and tunnels that copy's MCP server here. Needs E2E_PROVISIONING_PROFILE, which it remembers.
  probe      Runs raw CloudKit probes on both sides and writes what the server did to .build/logs/e2e/.
  run [--take-focus] [<scenario> ...]
             Deletes both accounts' data in the harness's container, starts both copies from no files, and runs the
             sharing scenarios, all or those named, writing what each found to .build/logs/e2e/. Run launch first.
             It keeps bringing the participant's copy to the front, so CloudKit fetches there at once: keep the
             participant unlocked, and don't use it meanwhile. This Mac's copy waits for pushes, which in Development
             can take over 20 minutes, so some checks time out; --take-focus brings it forward too, and keeps this
             Mac awake, so a run takes minutes, but this Mac can't be used meanwhile.
  quit       Quits both copies and closes the tunnel.
  unpair     Quits both copies, deletes the copy and its data from the participant, and forgets the key.

Both sides run `build.sh --e2e`, which syncs through a container of its own, iCloud.com.afollestad.reqling.e2e, in
CloudKit's Development environment, so a run never reaches Reqling Dev's data. It needs that container on the
com.afollestad.reqling.debug App ID, and a development profile for that App ID (E2E_PROVISIONING_PROFILE) listing this
Mac and the participant, registered under Devices by the UDID `pair` prints. A Developer ID profile won't do: it
allows only CloudKit's Production environment.

What this script keeps lives in ~/.config/reqling-e2e; on the participant, everything is under ~/ReqlingE2E. The VM,
icloud-participant, holds nothing else of Reqling's, so other projects' harnesses can pair with it too.
USAGE
}

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/reqling-e2e"
key_path="$config_dir/id_ed25519"
config_path="$config_dir/config"
endpoints_path="$config_dir/endpoints.json"
vm_log="$config_dir/vm.log"
# Named for no project: other projects' sharing harnesses, such as Markneat's, pair with the same VM and account.
vm_name=icloud-participant
# A macOS 27.2 guest's push service can't make its device key in a VM, so it gets no push token, which sign-in and
# CloudKit's change notifications both need (https://github.com/openai/tart/issues/1420). A macOS 26 guest gets one.
vm_image=https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw
# The participant's MCP server is tunneled to the same port here: the server checks `Host` names its own port.
owner_port=47811
participant_port=47812
remote_folder=ReqlingE2E

# A setting `pair` or `launch` recorded, such as PARTICIPANT.
setting() {
  if [ -f "$config_path" ]; then
    sed -n "s/^$1=//p" "$config_path" | tail -n 1
  fi
}

# Records setting $1 as $2, replacing any earlier value; with no $2, drops it.
remember() {
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"
  touch "$config_path"
  grep -v "^$1=" "$config_path" >"$config_path.new" || true
  if [ $# -gt 1 ]; then
    printf '%s=%s\n' "$1" "$2" >>"$config_path.new"
  fi
  mv "$config_path.new" "$config_path"
}

ssh_options=(-i "$key_path" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$config_dir/known_hosts")

require_tart() {
  if ! command -v tart >/dev/null 2>&1; then
    echo "error: tart isn't installed; run ./scripts/sharing-e2e.sh vm-setup" >&2
    exit 1
  fi
}

# `tart list` prints one VM a row: source, name, disk, size, accessed, and state.
vm_exists() {
  tart list 2>/dev/null | awk -v name="$vm_name" '$2 == name { found = 1 } END { exit !found }'
}

vm_running() {
  tart list 2>/dev/null | awk -v name="$vm_name" '$2 == name && tolower($0) ~ /running/ { found = 1 } END { exit !found }'
}

# Starts the VM unless it runs, with a window when $1 is --window.
start_vm() {
  require_tart
  if ! vm_exists; then
    echo "error: $vm_name doesn't exist; run ./scripts/sharing-e2e.sh vm-setup" >&2
    exit 1
  fi
  if ! vm_running; then
    mkdir -p "$config_dir"
    local graphics=--no-graphics
    if [ "${1:-}" = --window ]; then
      graphics=
    fi
    echo "Starting $vm_name${graphics:+ without a window} (log: $vm_log)..."
    nohup tart run ${graphics:+"$graphics"} "$vm_name" >"$vm_log" 2>&1 &
  fi
  # The VM's address can change between boots, so it's looked up each time rather than recorded.
  tart ip --wait 180 "$vm_name" >/dev/null
}

stop_vm() {
  require_tart
  if vm_running; then
    tart stop "$vm_name"
  fi
}

# `user@host` for the participant: the VM, at its current address, or the Mac `pair` recorded.
participant() {
  local vm_user
  vm_user=$(setting VM_USER)
  if [ -n "$vm_user" ]; then
    local ip
    if ! ip=$(tart ip "$vm_name" 2>/dev/null); then
      echo "error: $vm_name isn't running; run ./scripts/sharing-e2e.sh vm-start" >&2
      exit 1
    fi
    echo "$vm_user@$ip"
    return
  fi
  local target
  target=$(setting PARTICIPANT)
  if [ -z "$target" ]; then
    echo "error: no participant yet; run ./scripts/sharing-e2e.sh pair --vm or pair <user@host>" >&2
    exit 1
  fi
  echo "$target"
}

# Whether the participant can be reached without starting anything: a running VM, or a paired Mac.
participant_up() {
  if [ -n "$(setting VM_USER)" ]; then
    command -v tart >/dev/null 2>&1 && vm_running
  else
    [ -n "$(setting PARTICIPANT)" ]
  fi
}

# Runs a command on the participant, which `pair` recorded.
remote() {
  ssh "${ssh_options[@]}" -o BatchMode=yes "$(participant)" "$@"
}

vm_setup() {
  local image=${1:-$vm_image}
  if [ "$(uname -m)" != arm64 ]; then
    echo "error: tart's macOS VMs need Apple silicon" >&2
    exit 1
  fi
  if ! command -v tart >/dev/null 2>&1; then
    echo "Installing tart..."
    brew install openai/tools/tart
  fi
  if vm_exists; then
    echo "$vm_name already exists."
  else
    echo "Creating $vm_name from ${image##*/}. The download is about 20 GB."
    tart create "$vm_name" --from-ipsw "$image" --disk-size 60
    tart set "$vm_name" --cpu 4 --memory 8192
    # The VM no longer needs the restore image, and `prune` removes nothing without a budget.
    tart prune --entries caches --space-budget 0 >/dev/null
  fi
  # A VM's disk is one large file that changes constantly; Time Machine would copy all of it each hour.
  tmutil addexclusion "$HOME/.tart" 2>/dev/null || true
  cat <<'CHECKLIST'

In the VM window that opens, finish macOS Setup Assistant:
  1. Create a local account with any name and password; `pair --vm` asks for its account name and password.
  2. Sign in to your second Apple Account, at the Apple Account step or later in System Settings. A VM can't create
     one, and Apple refuses a new one in a VM ("Verification Failed") until it has signed in on a real Mac, such as
     in a second user account on this one, which then gets its codes.
  3. Leave FileVault off: automatic login needs it off.
Then, in the VM's System Settings:
  4. General > Sharing: turn on Remote Login.
  5. Users & Groups: set Automatically log in as your account.
  6. General > Software Update > Automatic Updates: turn everything off, so the VM stays on the macOS it was made with.
  7. Lock Screen: set Turn display off when inactive and Require password after screen saver begins or display is
     turned off to Never. A locked VM can't bring its copy of the app forward, which is how `run` makes it fetch at
     once; `launch` keeps the screen saver from starting while that copy runs.
Shut the VM down when you're done, then run ./scripts/sharing-e2e.sh pair --vm.
CHECKLIST
  tart run "$vm_name"
}

# The participant's Provisioning UDID, which the profile must list for the copy to launch there, as for this Mac.
participant_device() {
  remote 'system_profiler SPHardwareDataType' | awk -F': ' '/Provisioning UDID/ { print $2; exit }'
}

# Gives the participant this script's key, and checks its macOS and iCloud sign-in.
connect() {
  local target
  target=$(participant)
  if [ ! -f "$key_path" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "reqling-e2e" -f "$key_path"
  fi
  if ! remote true 2>/dev/null; then
    echo "Copying this script's SSH key to $target; type that account's password when asked."
    ssh-copy-id "${ssh_options[@]}" "$target" >/dev/null
  fi
  local version
  version=$(remote sw_vers -productVersion)
  if [ "${version%%.*}" -lt 26 ]; then
    echo "error: $target runs macOS $version; Reqling needs 26 or later" >&2
    exit 1
  fi
  if ! remote 'defaults read MobileMeAccounts Accounts' 2>/dev/null | grep -q AccountID; then
    echo "error: $target isn't signed in to iCloud; sign in under System Settings > Apple Account, then pair again" >&2
    exit 1
  fi
  # Asked each time, since a new participant has another account.
  local email current
  current=$(setting PARTICIPANT_EMAIL)
  read -r -p "The email address of the participant's Apple Account, which the probes invite${current:+ [$current]}: " email
  remember PARTICIPANT_EMAIL "${email:-$current}"
  echo "$target is paired: macOS $version, signed in to iCloud, Provisioning UDID $(participant_device)."
}

pair() {
  if [ $# -ne 1 ]; then
    usage >&2
    exit 1
  fi
  if [ "$1" != --vm ]; then
    remember VM_USER
    remember PARTICIPANT "$1"
    connect
    return
  fi
  start_vm
  # Asked each time, so a wrong name can be corrected.
  local user current
  current=$(setting VM_USER)
  read -r -p "The account name of the VM's user, as \`whoami\` in the VM prints it${current:+ [$current]}: " user
  user=${user:-$current}
  remember PARTICIPANT
  remember VM_USER "$user"
  connect
  echo "Keeping the VM awake; type the VM account's password if sudo asks."
  ssh -t "${ssh_options[@]}" "$(participant)" 'sudo pmset -a sleep 0 displaysleep 0 disksleep 0' >/dev/null
}

# `open` needs the participant's account logged in, which a VM is a little after it boots.
wait_for_login() {
  local tries=0
  # shellcheck disable=SC2016 # Expanded on the participant.
  until remote 'pgrep -x -u "$USER" Dock' >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 60 ]; then
      echo "error: no one is logged in on $(participant); turn on automatic login there" >&2
      exit 1
    fi
    sleep 2
  done
}

# The harness's copy of the app, on this Mac.
e2e_app() {
  app_path e2e
}

harness_config() {
  printf '{"directory": "%s", "port": %s, "token": "%s"}\n' "$1" "$2" "$3"
}

launch() {
  local profile=${E2E_PROVISIONING_PROFILE:-$(setting E2E_PROVISIONING_PROFILE)}
  if [ -z "$profile" ]; then
    echo "error: set E2E_PROVISIONING_PROFILE to a development profile for com.afollestad.reqling.debug" >&2
    exit 1
  fi
  remember E2E_PROVISIONING_PROFILE "$profile"
  if [ -n "$(setting VM_USER)" ]; then
    start_vm
  fi
  local target device
  target=$(participant)
  wait_for_login
  device=$(participant_device)
  if [ -z "$device" ]; then
    echo "error: $target reported no Provisioning UDID" >&2
    exit 1
  fi
  quit_apps
  E2E_PROVISIONING_PROFILE="$profile" E2E_PARTICIPANT_DEVICE="$device" "$repo_root/scripts/build.sh" --e2e
  remote "mkdir -p $remote_folder"
  rsync -a --delete -e "ssh ${ssh_options[*]}" "$(e2e_app)/" "$target:$remote_folder/Reqling.app/"
  start_apps
}

# Starts both copies of the built app, each with a new token, and tunnels the participant's MCP server here.
start_apps() {
  local target owner_token participant_token remote_home pid participant_forward owner_forward
  target=$(participant)
  owner_token=$(uuidgen)
  participant_token=$(uuidgen)
  # shellcheck disable=SC2016 # Expanded on the participant.
  remote_home=$(remote 'echo $HOME')
  harness_config "$remote_home/$remote_folder/Data" "$participant_port" "$participant_token" | remote "cat > $remote_folder/harness.json"
  remote "open -n -g $remote_folder/Reqling.app --args -DebugSharingHarness $remote_home/$remote_folder/harness.json"
  # After 20 minutes without input, the screen saver starts, and on macOS 26 it brings up the lock screen, which nothing
  # comes forward over; holding the display awake for as long as this copy runs keeps the screen saver from starting.
  if ! pid=$(remote "pgrep -nf '$remote_folder/Reqling.app/Contents/MacOS/$app_name'"); then
    echo "error: the participant's copy didn't start" >&2
    exit 1
  fi
  remote "nohup caffeinate -d -w $pid </dev/null >/dev/null 2>&1 &"
  harness_config "$config_dir/Owner" "$owner_port" "$owner_token" >"$config_dir/owner.json"
  open -n -g "$(e2e_app)" --args -DebugSharingHarness "$config_dir/owner.json"
  ssh -f -N "${ssh_options[@]}" -o ExitOnForwardFailure=yes -L "$participant_port:127.0.0.1:$participant_port" "$target"
  participant_forward=$(json_array ssh "${ssh_options[@]}" -o BatchMode=yes "$target" "$(come_forward_script "$remote_folder/Reqling.app")")
  owner_forward=$(json_array bash -c "$(come_forward_script "$(e2e_app)")")
  cat >"$endpoints_path" <<ENDPOINTS
{
  "owner": {"port": $owner_port, "token": "$owner_token", "comeForward": $owner_forward},
  "participant": {"port": $participant_port, "token": "$participant_token", "email": "$(setting PARTICIPANT_EMAIL)",
                  "comeForward": $participant_forward}
}
ENDPOINTS
  chmod 600 "$endpoints_path" "$config_dir/owner.json"
  echo "Both copies are running: the owner here on port $owner_port, the participant on $target, tunneled to $participant_port."
}

# What the runner runs where the copy at $1 runs before each of that copy's syncs: Finder to the front, then the copy,
# waiting for each. CloudKit fetches at once only as the app becomes active, and the copy can't make itself active,
# since macOS's cooperative activation ignores `activate()` from an app in the background. $1 is absolute, or relative
# to the home folder.
come_forward_script() {
  local app suffix
  app=$(printf '%q' "$1")
  suffix=$(printf '%q' "/${1#/}")
  # shellcheck disable=SC2016 # Expanded where it runs.
  printf '%s' 'await_front() { tries=0; until /usr/bin/lsappinfo info -only bundlepath "$(/usr/bin/lsappinfo front)" | grep -qF -- "$1\""; do' \
    ' tries=$((tries + 1)); if [ "$tries" -ge 100 ]; then echo "$1 never came to the front; is the screen locked?" >&2; return 1; fi;' \
    ' sleep 0.1; done; }; ' \
    "open -a Finder && await_front /Finder.app && open $app && await_front $suffix"
}

# Its arguments as a JSON array of strings.
json_array() {
  python3 -I -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@"
}

# Quits both copies and closes the tunnel, waiting until each copy has exited, so nothing writes to its files after.
quit_apps() {
  local here="$(e2e_app)/Contents/MacOS/$app_name" there="$remote_folder/Reqling.app/Contents/MacOS/$app_name" tries=0
  pkill -f "$here" 2>/dev/null || true
  pkill -f "ssh .*-L $participant_port:127.0.0.1:$participant_port" 2>/dev/null || true
  if participant_up; then
    remote "pkill -f '$there'" 2>/dev/null || true
  fi
  while pgrep -f "$here" >/dev/null || { participant_up && remote "pgrep -f '$there'" >/dev/null 2>&1; }; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      echo "error: a copy of the app didn't quit" >&2
      exit 1
    fi
    sleep 1
  done
}

# Resets both accounts' data in the harness's container, starts both copies from no files, and runs the scenarios.
run_scenarios() {
  if [ ! -f "$endpoints_path" ]; then
    echo "error: run ./scripts/sharing-e2e.sh launch first" >&2
    exit 1
  fi
  local runner=(python3 -I "$repo_root/scripts/lib/sharing_scenarios.py") take_focus=()
  if [ "${1:-}" = --take-focus ]; then
    take_focus=(--take-focus)
    shift
  fi
  "${runner[@]}" reset "$endpoints_path"
  quit_apps
  rm -rf "$config_dir/Owner"
  remote "rm -rf $remote_folder/Data"
  start_apps
  if [ ${#take_focus[@]} -gt 0 ]; then
    # As on the participant, so the screen saver doesn't lock this Mac while the runner brings this copy forward.
    nohup caffeinate -d -w "$(pgrep -nf "$(e2e_app)/Contents/MacOS/$app_name")" </dev/null >/dev/null 2>&1 &
  fi
  mkdir -p "$logs_dir/e2e"
  "${runner[@]}" run "$endpoints_path" "$logs_dir/e2e/scenarios-$(date +%Y%m%d-%H%M%S).json" ${take_focus[@]+"${take_focus[@]}"} "$@"
}

probe() {
  if [ ! -f "$endpoints_path" ]; then
    echo "error: run ./scripts/sharing-e2e.sh launch first" >&2
    exit 1
  fi
  mkdir -p "$logs_dir/e2e"
  python3 -I "$repo_root/scripts/lib/sharing_probes.py" "$endpoints_path" "$logs_dir/e2e/probes-$(date +%Y%m%d-%H%M%S).json"
}

unpair() {
  quit_apps
  local deleted="this script's key and settings"
  if participant_up && remote "rm -rf $remote_folder" 2>/dev/null; then
    deleted="the copy and its data from the participant, and $deleted"
  fi
  rm -rf "$config_dir"
  echo "Deleted $deleted."
}

vm_delete() {
  require_tart
  local answer
  read -r -p "Delete $vm_name, which other projects' harnesses may use too? [y/N] " answer
  if [ "$answer" != y ] && [ "$answer" != Y ]; then
    exit 1
  fi
  if [ -n "$(setting VM_USER)" ]; then
    # The VM goes whole, so its copy needn't be deleted first.
    quit_apps
    rm -rf "$config_dir"
  fi
  stop_vm
  if vm_exists; then
    tart delete "$vm_name"
  fi
  tart prune --entries caches --space-budget 0 >/dev/null
  tmutil removeexclusion "$HOME/.tart" 2>/dev/null || true
  echo "Deleted $vm_name and tart's caches. \`brew uninstall tart\` removes tart itself."
}

case "${1:-}" in
  vm-setup) shift; vm_setup "$@" ;;
  vm-start) shift; start_vm "$@"; echo "$vm_name is running." ;;
  vm-stop) stop_vm ;;
  vm-delete) vm_delete ;;
  pair) shift; pair "$@" ;;
  launch) launch ;;
  probe) probe ;;
  run) shift; run_scenarios "$@" ;;
  quit) quit_apps ;;
  unpair) unpair ;;
  -h|--help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
