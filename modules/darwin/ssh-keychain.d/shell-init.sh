# shellcheck shell=bash
# @codebase
# Source from interactive bash/zsh shells to attach to a reusable ssh-agent
# and load runtime-managed SSH private keys from canonical /run secrets paths.

if [[ -n "${__NXMATIC_SSH_KEYCHAIN_INIT:-}" ]]; then
  return 0
fi
__NXMATIC_SSH_KEYCHAIN_INIT=1

state_keys_dir="@userKeysDir@"
keys_yaml_file="@keysYamlPath@"
keychain_bin="@keychainBin@"
ssh_add_bin="@sshAddBin@"
ssh_keygen_bin="@sshKeygenBin@"
launchctl_bin="@launchctlBin@"
ssh_keychain_keys=()

ssh_keychain_is_private_key() {
  local candidate="$1"
  [[ -f "$candidate" ]] || return 1
  case "$candidate" in
    *.pub|*-cert.pub|*-ca.pub|*/keys.yaml)
      return 1
      ;;
  esac
  "$ssh_keygen_bin" -y -f "$candidate" >/dev/null 2>&1
}

ssh_keychain_add_candidate() {
  local candidate="$1"
  local existing

  ssh_keychain_is_private_key "$candidate" || return 1
  for existing in "${ssh_keychain_keys[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  ssh_keychain_keys+=("$candidate")
}

ssh_keychain_collect_yaml_keys() {
  local key_name
  local candidate

  [[ -r "$keys_yaml_file" ]] || return 0
  while IFS= read -r key_name; do
    [[ -n "$key_name" ]] || continue
    [[ "$key_name" == \#* ]] && continue
    candidate="${state_keys_dir}/${key_name}"
    ssh_keychain_add_candidate "$candidate" || true
  done < <(yq eval '.keys | keys[]' "$keys_yaml_file" 2>/dev/null || true)
}

ssh_keychain_collect_fallback_keys() {
  local candidate

  for candidate in "$state_keys_dir"/host "$state_keys_dir"/host-*; do
    [[ -e "$candidate" ]] || continue
    ssh_keychain_add_candidate "$candidate" || true
  done
}

ssh_keychain_cleanup_cert() {
  local key_path="$1"
  local cert_path="${key_path}-cert.pub"
  local key_fp
  local cert_fp

  [[ -f "$cert_path" ]] || return 0

  key_fp="$($ssh_keygen_bin -lf "$key_path" 2>/dev/null | awk '{print $2}' || true)"
  cert_fp="$($ssh_keygen_bin -Lf "$cert_path" 2>/dev/null | awk '/Public key:/ {print $4; exit}' || true)"
  if [[ -n "$key_fp" && -n "$cert_fp" && "$key_fp" != "$cert_fp" ]]; then
    rm -f "$cert_path"
  fi
}

ssh_keychain_eval() {
  [[ ${#ssh_keychain_keys[@]} -gt 0 ]] || return 0
  eval "$($keychain_bin --quiet --eval "${ssh_keychain_keys[@]}")"
}

ssh_keychain_restore_launchd_socket() {
  local launchd_sock

  [[ -x "$launchctl_bin" ]] || return 0
  launchd_sock="$($launchctl_bin getenv SSH_AUTH_SOCK 2>/dev/null || true)"
  if [[ -n "$launchd_sock" ]]; then
    export SSH_AUTH_SOCK="$launchd_sock"
    unset SSH_AGENT_PID
  fi
}

ssh_keychain_add_missing_keys() {
  local key_path

  for key_path in "${ssh_keychain_keys[@]}"; do
    ssh_keychain_cleanup_cert "$key_path"
    "$ssh_add_bin" -q "$key_path" </dev/null >/dev/null 2>&1 || true
  done
}

ssh_keychain_init() {
  local ssh_add_status

  [[ -d "$state_keys_dir" ]] || return 0
  [[ -x "$keychain_bin" ]] || return 0
  [[ -x "$ssh_add_bin" ]] || return 0
  [[ -x "$ssh_keygen_bin" ]] || return 0

  ssh_keychain_collect_yaml_keys
  if [[ ${#ssh_keychain_keys[@]} -eq 0 ]]; then
    ssh_keychain_collect_fallback_keys
  fi
  [[ ${#ssh_keychain_keys[@]} -gt 0 ]] || return 0

  ssh_keychain_eval

  "$ssh_add_bin" -l >/dev/null 2>&1
  ssh_add_status=$?
  if [[ $ssh_add_status -eq 2 ]]; then
    unset SSH_AUTH_SOCK SSH_AGENT_PID
    ssh_keychain_eval

    "$ssh_add_bin" -l >/dev/null 2>&1
    ssh_add_status=$?
    if [[ $ssh_add_status -eq 2 ]]; then
      ssh_keychain_restore_launchd_socket
    fi
  fi

  "$ssh_add_bin" -l >/dev/null 2>&1
  ssh_add_status=$?
  if [[ $ssh_add_status -eq 1 ]]; then
    ssh_keychain_add_missing_keys
  fi
}

ssh_keychain_init

unset -f \
  ssh_keychain_is_private_key \
  ssh_keychain_add_candidate \
  ssh_keychain_collect_yaml_keys \
  ssh_keychain_collect_fallback_keys \
  ssh_keychain_cleanup_cert \
  ssh_keychain_eval \
  ssh_keychain_restore_launchd_socket \
  ssh_keychain_add_missing_keys \
  ssh_keychain_init
unset keychain_bin keys_yaml_file launchctl_bin ssh_add_bin ssh_keygen_bin ssh_keychain_keys state_keys_dir
