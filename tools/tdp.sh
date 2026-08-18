#!/usr/bin/env bash
# tdp.sh - set the sustained power limit (TDP) on a Ryzen 5825U via ryzenadj.
#
# Measured on this GMKtec M5 PLUS after repaste + VRM thermal putty:
#
#   limits set   actual sustained   all-core clocks   throughput
#   35 W (stock)      32.8 W          3192 MHz        17661 bogo/s
#   45 W              42.3 W          3396 MHz        18145 bogo/s
#   50-55 W        ~46 W (ceiling)    ~3490 MHz       19400 bogo/s
#
# Power saturates near 46-47 W because the die reaches its 93 C limit
# (Tjmax is 95 C, and the 93 C ceiling cannot be raised - the BIOS clips
# any tctl-temp write above it). So values above ~50 W raise a ceiling
# that nothing actually reaches. Neither fan speed nor the current limits
# (TDC/EDC) were found to be limiting.
#
# All changes are volatile: they are lost on reboot, and the SMU also
# resets them on suspend/resume. Use `hold` if you want them re-applied.

set -uo pipefail

STOCK_W=35
STOCK_APU=42
STOCK_TDC=51000
STOCK_EDC=105000
STOCK_TCTL=93

MIN_W=10
MAX_W=65

# Re-exec inside a nix shell if ryzenadj is not on PATH.
if ! command -v ryzenadj >/dev/null 2>&1; then
  if [ "${TDP_SH_REEXEC:-0}" = "1" ]; then
    echo "error: ryzenadj still not available after nix shell" >&2
    exit 1
  fi
  exec env TDP_SH_REEXEC=1 nix shell nixpkgs#ryzenadj --command "$0" "$@"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "error: must run as root (ryzenadj needs /dev/mem or ryzen_smu)" >&2
  exit 1
fi

field() {
  ryzenadj --info 2>/dev/null | awk -F'|' -v k="$1" '
    index($2,k) {gsub(/ /,"",$3); print $3; exit}'
}

show() {
  printf '  %-16s %s W\n'  "STAPM limit"   "$(field 'STAPM LIMIT')"
  printf '  %-16s %s W\n'  "PPT fast"      "$(field 'PPT LIMIT FAST')"
  printf '  %-16s %s W\n'  "PPT slow"      "$(field 'PPT LIMIT SLOW')"
  printf '  %-16s %s W\n'  "PPT APU"       "$(field 'PPT LIMIT APU')"
  printf '  %-16s %s A\n'  "TDC (VDD)"     "$(field 'TDC LIMIT VDD')"
  printf '  %-16s %s A\n'  "EDC (VDD)"     "$(field 'EDC LIMIT VDD')"
  printf '  %-16s %s C\n'  "Thermal limit" "$(field 'THM LIMIT CORE')"
  printf '  ---- live ----\n'
  printf '  %-16s %s W\n'  "power now"     "$(field 'PPT VALUE SLOW')"
  printf '  %-16s %s C\n'  "temp now"      "$(field 'THM VALUE CORE')"
}

apply() { # apply <watts> [raise_current]
  local w="$1" raise="${2:-0}"
  local args=(
    "--stapm-limit=$((w * 1000))"
    "--fast-limit=$((w * 1000))"
    "--slow-limit=$((w * 1000))"
    "--apu-slow-limit=$(((w + 7) * 1000))"
  )
  # Headroom on the current limits. Not needed at <=55 W on this board
  # (TDC peaked at 40/60 A and EDC at 80/115 A), but harmless.
  if [ "$raise" = "1" ]; then
    args+=( "--vrm-current=60000" "--vrmmax-current=115000" )
  fi
  ryzenadj "${args[@]}" >/dev/null 2>&1
  local rc=$?
  sleep 1
  local got
  got=$(field 'PPT LIMIT SLOW')
  if [ "${got%%.*}" != "$w" ]; then
    echo "warning: asked for ${w} W but PPT slow reads ${got} W (BIOS may have clipped it)" >&2
  fi
  return $rc
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <watts> [--max-current]
       $(basename "$0") status
       $(basename "$0") reset
       $(basename "$0") hold <watts> [interval_seconds]
       $(basename "$0") watch [seconds]

  <watts>        Set sustained power limit. Sensible values: 30 40 45 50 55 60
                 (${MIN_W}-${MAX_W} accepted). Measured ceiling on this machine
                 is ~46 W actual, reached with a 50 W setting; higher values
                 change nothing because the 93 C thermal limit binds first.
  --max-current  Also raise TDC to 60 A and EDC to 115 A (their hard caps).
                 Not required at <=55 W; neither was observed to bind.
  status         Show current limits and live power/temperature.
  reset          Restore factory limits (${STOCK_W} W / ${STOCK_APU} W APU /
                 ${STOCK_TDC%000} A / ${STOCK_EDC%000} A / ${STOCK_TCTL} C).
  hold           Apply and re-apply periodically (default every 60 s), so the
                 setting survives suspend/resume. Ctrl-C to stop.
  watch          Print live power, temperature and clocks.

Examples:
  sudo $0 50              # the sweet spot on this machine
  sudo $0 40              # milder
  sudo $0 status
  sudo $0 reset
  sudo $0 hold 50         # keep 50 W applied across resume
EOF
}

avgfreq() {
  local s=0 n=0 c
  for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    s=$((s + $(cat "$c"))); n=$((n + 1))
  done
  echo $((s / n / 1000))
}

cmd="${1:-status}"

case "$cmd" in
  status)
    echo "Current power management state:"
    show
    ;;

  reset)
    echo "Restoring factory limits..."
    ryzenadj --stapm-limit=$((STOCK_W * 1000)) \
             --fast-limit=$((STOCK_W * 1000)) \
             --slow-limit=$((STOCK_W * 1000)) \
             --apu-slow-limit=$((STOCK_APU * 1000)) \
             --vrm-current="$STOCK_TDC" \
             --vrmmax-current="$STOCK_EDC" \
             --tctl-temp="$STOCK_TCTL" >/dev/null 2>&1
    sleep 1
    show
    ;;

  watch)
    secs="${2:-0}"
    end=0
    [ "$secs" -gt 0 ] 2>/dev/null && end=$(( $(date +%s) + secs ))
    printf '%-9s %-9s %-9s %-9s %-9s %s\n' time pptslow stapm edc temp freq
    while :; do
      printf '%-9s %-9s %-9s %-9s %-9s %sMHz\n' \
        "$(date +%H:%M:%S)" "$(field 'PPT VALUE SLOW')" "$(field 'STAPM VALUE')" \
        "$(field 'EDC VALUE VDD')" "$(field 'THM VALUE CORE')" "$(avgfreq)"
      [ "$end" -ne 0 ] && [ "$(date +%s)" -ge "$end" ] && break
      sleep 2
    done
    ;;

  hold)
    w="${2:-}"
    iv="${3:-60}"
    [ -z "$w" ] && { usage; exit 1; }
    case "$w" in *[!0-9]*|'') echo "error: watts must be an integer" >&2; exit 1;; esac
    if [ "$w" -lt "$MIN_W" ] || [ "$w" -gt "$MAX_W" ]; then
      echo "error: watts must be ${MIN_W}-${MAX_W}" >&2
      exit 1
    fi
    echo "Holding ${w} W, re-applying every ${iv}s. Ctrl-C to stop."
    trap 'echo; echo "stopped (limits left at ${w} W; reboot or \"reset\" restores stock)"; exit 0' INT TERM
    while :; do
      apply "$w" 0
      printf '  %s  applied %sW  (live %sW, %sC)\n' \
        "$(date +%H:%M:%S)" "$w" "$(field 'PPT VALUE SLOW')" "$(field 'THM VALUE CORE')"
      sleep "$iv"
    done
    ;;

  -h|--help|help)
    usage
    ;;

  *)
    case "$cmd" in *[!0-9]*|'') echo "error: '$cmd' is not a watt value"; echo; usage; exit 1;; esac
    if [ "$cmd" -lt "$MIN_W" ] || [ "$cmd" -gt "$MAX_W" ]; then
      echo "error: watts must be between ${MIN_W} and ${MAX_W}" >&2
      exit 1
    fi
    raise=0
    [ "${2:-}" = "--max-current" ] && raise=1
    if [ "$cmd" -gt 55 ]; then
      echo "note: ${cmd} W is above the measured ~46 W thermal ceiling; expect no gain over 50 W."
    fi
    echo "Setting sustained power limit to ${cmd} W..."
    apply "$cmd" "$raise"
    show
    echo
    echo "Volatile: lost on reboot and on suspend/resume. Use 'hold ${cmd}' to keep it applied."
    ;;
esac
