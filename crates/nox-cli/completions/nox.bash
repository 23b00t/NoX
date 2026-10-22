# bash completion for nox. VM names come from /etc/nox/registry.json (a
# JSON list of names, written by the NixOS module programs.nox).

_nox_vms() {
  local f=/etc/nox/registry.json
  [ -r "$f" ] && tr -d '[]"' <"$f" | tr ',' ' '
}

_nox() {
  local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]-} words="" i n=0
  if [ "$COMP_CWORD" -eq 1 ]; then
    words="list ls start stop restart disp backup pull run exec ssh clip copy update usb doctor rollback snapshot gc xen nix root help --help --version"
    mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
    return
  fi
  # positional words between the command and the cursor
  for ((i = 2; i < COMP_CWORD; i++)); do
    [[ ${COMP_WORDS[i]} == -* ]] || n=$((n + 1))
  done
  case "$cmd" in
    list | ls) words="--running --stale --group" ;;
    start | restart) words="$(_nox_vms) --running --stale --group --fresh" ;;
    stop) words="$(_nox_vms) --running --stale --group" ;;
    run | exec | ssh)
      if [ "$n" -eq 0 ]; then
        words="$(_nox_vms)"
      elif [ "$n" -eq 1 ] && [ "$cmd" != ssh ]; then
        mapfile -t COMPREPLY < <(compgen -c -- "$cur")
        return
      else
        compopt -o default
        COMPREPLY=()
        return
      fi
      ;;
    clip) [ "$n" -eq 0 ] && words="copy paste" ;;
    copy)
      if [[ $cur == -* ]]; then
        words="-m --move -n --dry-run --max"
      elif [ "$n" -eq 0 ]; then
        words="$(_nox_vms)"
      elif [ "$n" -eq 1 ]; then
        # the target VM (after a source VM) or already a file
        compopt -o default
        mapfile -t COMPREPLY < <(compgen -W "$(_nox_vms)" -- "$cur")
        return
      else
        compopt -o default
        COMPREPLY=()
        return
      fi
      ;;
    backup)
      # home: <vm>… | --all; --full [--level N] <vm>[:disk,…] | dom0 | builder | --all
      if [ "$n" -eq 0 ]; then
        words="$(_nox_vms) --all --full --level restore disks list prune help"
        [[ " ${COMP_WORDS[*]} " == *" --full "* ]] && words="$words dom0 builder"
      else
        case "${COMP_WORDS[2]}" in
          restore) words="$(_nox_vms) dom0 builder --all --full --from" ;;
          disks) words="$(_nox_vms) --all" ;;
          prune) if [ "$n" -eq 1 ]; then words="home full"; else words="$(_nox_vms) dom0 builder --keep -n"; fi ;;
          list | help) words="" ;;
          *) words="$(_nox_vms) dom0 builder --all --full --level" ;;
        esac
      fi
      ;;
    pull) [ "$n" -eq 0 ] && words="$(_nox_vms)" ;;
    update) words="--all --switch --machine --branch" ;;
    rollback) if [ "$n" -eq 0 ]; then words="$(_nox_vms) --data"; else words="--gen --reset"; fi ;;
    snapshot) [ "$n" -eq 0 ] && words="$(_nox_vms)" ;;
    gc) words="--keep --dry-run" ;;
    usb)
      if [ "$n" -eq 0 ]; then
        words="list ls attach detach allow-input"
      elif [ "${COMP_WORDS[2]}" = attach ] && [ "$n" -eq 2 ]; then
        words="$(_nox_vms)"
      fi
      ;;
  esac
  mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

complete -F _nox nox
