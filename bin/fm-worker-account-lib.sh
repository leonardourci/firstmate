#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# account pin: which runners can be pinned, how a pin file is parsed and
# resolved, the launch-time sign-in check under it, and the environment
# credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Worker account pin" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login.
#
# config/claude-account may list several logins, one per line, in fallback
# order. A one-line file behaves exactly as a single pin always has. With two
# or more, each launch walks the list in order: a login that is not signed in
# refuses the launch, as a single pin does, rather than being skipped; a
# signed-in login whose own quota-axi read shows a bound for the launch model
# exhausted_now or known at 0% is skipped; the first other login is chosen,
# including one whose quota is unknown or unreadable. When every listed login
# is spent, the launch refuses; nothing falls back to an unlisted login. A
# relaunch whose task record names a login the file still lists reuses that
# login without walking, so a running task never switches accounts.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}
FM_WORKER_ACCOUNT_QUOTA_SECONDS=${FM_WORKER_ACCOUNT_QUOTA_SECONDS:-30}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# Prints "declared<TAB>providers" for a valid pin, where declared is
# `ordinary` or the absolute path and providers is empty for Claude; a Claude
# pin listing several logins prints one such line per login, in file order. The final
# newline is optional; any other control byte, including a CR, is malformed.
# Parses bytes before the shell can drop NULs or trailing newlines; paths are
# literal, never shell expressions. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      $body =~ /\A((?:(?:ordinary|\/[^\x00-\x1f\x7f]*)\n)*(?:ordinary|\/[^\x00-\x1f\x7f]*))\n?\z/ or exit 6;
      print "$_\t\n" for split /\n/, $1;
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2, "\n";
    }
  ' -- "$1" "$2"
}

# fm_worker_account_resolve <harness> <config-dir>
# Prints "declared<TAB>root<TAB>providers" for a valid pin, where root is the
# directory the launch selects (empty for ordinary Claude, meaning
# CLAUDE_CONFIG_DIR unset), one line per listed Claude login in fallback
# order. Prints nothing and returns 0 when the runner is
# not pinnable or the home has no pin. On refusal prints one error naming the
# file and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 file cfg tokens token rc declared root fallback
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  tokens=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: config/$file must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: config/$file must hold 'ordinary' or an absolute path on each line, one login per line in fallback order, with no blank lines or control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *) fallback='~/.pi/agent' ;;
  esac
  while IFS= read -r token; do
    declared=${token%%$'\t'*}
    root=$declared
    if [ "$declared" = ordinary ]; then
      case "$harness" in
      claude) root= ;;
      *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
      esac
    fi
    if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
      echo "error: config/$file must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
      return 1
    fi
    printf '%s\t%s\t%s\n' "$declared" "$root" "${token#*$'\t'}"
  done <<< "$tokens"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} out verdict name
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  case "$harness" in
  claude)
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: config/claude-account pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: config/claude-account pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: config/pi-account pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_claude_quota_row <root>
# Prints the Claude provider row of one quota-axi read made under that login
# (CLAUDE_CONFIG_DIR=<root>, or unset for an empty root), as compact JSON, or
# null when quota-axi is missing, fails, times out, or prints no valid
# snapshot. The read sheds the same credentials a pinned launch sheds, plus
# CLAUDE_SECURESTORAGE_CONFIG_DIR, which would otherwise select another
# Keychain item, so it measures the account the worker would spend.
fm_worker_account_claude_quota_row() {
  local root=$1 var out
  local -a cmd=(env -u CLAUDE_SECURESTORAGE_CONFIG_DIR)
  command -v quota-axi >/dev/null 2>&1 || { echo null; return 0; }
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    cmd+=(-u "$var")
  done
  if [ -n "$root" ]; then
    cmd+=("CLAUDE_CONFIG_DIR=$root")
  else
    cmd+=(-u CLAUDE_CONFIG_DIR)
  fi
  out=$(fm_run_timed "$FM_WORKER_ACCOUNT_QUOTA_SECONDS" "${cmd[@]}" \
    quota-axi --provider claude --json 2>/dev/null </dev/null) || out=
  if printf '%s\n' "$out" | fm_quota_json_valid >/dev/null 2>&1; then
    printf '%s\n' "$out" | jq -c "$FM_QUOTA_ROW_JQ"' quota_row(.; "claude"; "")' 2>/dev/null && return 0
  fi
  echo null
}

# fm_worker_account_claude_spent <row-json> <model>
# Returns 0 and prints "<scope> <remaining>%" or "<scope> exhausted_now" when
# the row has a bound for <model> that quota_spent (bin/fm-quota-axi-lib.sh)
# counts as out; returns 1, printing nothing, when the login has room or its
# quota is unknown.
fm_worker_account_claude_spent() {
  jq -ner --argjson row "$1" --arg model "$2" "$FM_QUOTA_ROW_JQ"'
    quota_spent($row; $model) // empty |
    "\(.scope) \(if (.runway.status // "") == "exhausted_now" then "exhausted_now" else "\(.effectivePercentRemaining)%" end)"' 2>/dev/null
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command>] [<recorded>]
# The whole launch-time decision. Prints nothing for an unpinned runner, so
# the caller keeps today's launch unchanged. For a pinned one prints
# "declared<TAB>root<TAB>provider", where provider is the Pi launch model's
# own (empty for Claude), after the model guard, the sign-in check, and, for
# a Claude list of two or more logins, the quota walk the header describes.
# <recorded> is a relaunching Claude task's recorded account=; when the file
# still lists it, the walk tries it first, so a relaunch keeps it while it has
# room and otherwise walks the rest of the list in order. On refusal prints
# one error and returns 1. bin/fm-spawn.sh runs it before any endpoint
# exists, and bin/fm-control.sh before a relaunch stops the live agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} recorded=${6:-}
  local selection declared root providers word line row spent spentlist='' provider=
  local -a logins=()
  selection=$(fm_worker_account_resolve "$harness" "$config") || return 1
  [ -n "$selection" ] || return 0
  if [ "$harness" = claude ]; then
    while IFS= read -r line; do
      if [ -n "$recorded" ] && [ "${line%%$'\t'*}" = "$recorded" ]; then
        logins=("$line" ${logins[@]+"${logins[@]}"})
      else
        logins+=("$line")
      fi
    done <<< "$selection"
    selection=${logins[0]}
  fi
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  providers=${root#*$'\t'}
  root=${root%%$'\t'*}
  if [ "$harness" = claude ]; then
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
        *" ${word%%=*} "*)
          echo "error: config/claude-account pins Claude workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove config/claude-account" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
  else
    if [ -n "$raw" ]; then
      echo "error: config/pi-account pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: config/pi-account pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: config/pi-account pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
  fi
  if [ "$harness" = claude ] && [ "${#logins[@]}" -gt 1 ]; then
    for line in "${logins[@]}"; do
      declared=${line%%$'\t'*}
      root=${line#*$'\t'}
      root=${root%%$'\t'*}
      fm_worker_account_check claude "$declared" "$root" "$executable" || return 1
      row=$(fm_worker_account_claude_quota_row "$root")
      if spent=$(fm_worker_account_claude_spent "$row" "$model"); then
        spentlist="$spentlist${spentlist:+; }$declared: $spent"
        continue
      fi
      printf '%s\t%s\t\n' "$declared" "$root"
      return 0
    done
    echo "error: every Claude login config/claude-account allows is out of usage ($spentlist), so no Claude worker starts and no unlisted login is used; wait for a usage reset or dispatch another harness" >&2
    return 1
  fi
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" || return 1
  printf '%s\t%s\t%s\n' "$declared" "$root" "$provider"
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
