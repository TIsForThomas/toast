#!/bin/sh
# TOAST - the pieces every kit script needs: how to read an answer from a
# person, and how to power a unit off.
#
# Sourced by all five scripts, never duplicated.
#
# ONE copy, sourced by ocs-prerun.sh, ocs-deploy.sh and ocs-shrink.sh, for the
# same reason UnitDiagnostics keeps _Common.ps1 in one place: three prompts on
# one USB stick that behave differently from each other is a support call.
#
# Rules, every one of them paid for on the bench:
#   * A typo is not a decision. Every prompt re-asks, up to three times.
#   * An unrecognised answer is NEVER read as a no. Until 1.9 anything that was
#     not a yes counted as a no, so "yse" silently abandoned a capture.
#   * Nothing is assumed when there is no answer to read (no keyboard, or input
#     redirected). That returns failure and the caller stops; it never guesses.
#   * Prompts and guidance go to STDERR, so a function whose ANSWER is captured
#     with $( ) can still talk to the operator.
#
# The words each option accepts are listed by the caller, so a person can type
# the number or the word. Both are things people actually type at a numbered
# list, and neither should be wrong.
#
# ⛔ None of this relaxes the two prompts that exist to destroy data. The deploy
# entry still makes you type the target disk's own serial number back, and
# write-kit still makes you type ERASE. Those are there to make a person stop
# and read, and a one-key confirmation would defeat them.

TOAST_ASK_TRIES=${TOAST_ASK_TRIES:-3}

# Fold an answer to something comparable: lower case, and drop the spaces and
# stray punctuation that come from typing in a hurry.
toast_fold() {
    printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | tr -d ' .!,\t\r'
}

# yes | no | none | other
answer_kind() {
    case "$(toast_fold "${1:-}")" in
        y|ye|yes|yeah|yep|yup|ok|okay|sure|go|continue|proceed|correct) echo yes ;;
        n|no|nope|nah|stop|cancel|quit|exit|abort|back)                 echo no ;;
        '')                                                            echo none ;;
        *)                                                             echo other ;;
    esac
}

# ask_line "prompt" -> the raw line on stdout. Returns 1 if there is no answer
# to be had, which is not the same as an empty answer.
ask_line() {
    printf '%s' "$1" >&2
    if ! read -r _tl 2>/dev/null; then
        echo "" >&2
        echo " Nothing could be read from the keyboard." >&2
        return 1
    fi
    printf '%s\n' "$_tl"
}

# ask_yes_no "prompt" -> 0 for yes, 1 for no or for no usable answer.
# Blank and unrecognised both re-ask rather than being taken as either answer.
ask_yes_no() {
    _yt=0
    while [ "$_yt" -lt "$TOAST_ASK_TRIES" ]; do
        _yt=$((_yt + 1))
        printf '%s' "$1"
        if ! read -r _ya 2>/dev/null; then
            echo ""
            echo " Nothing could be read from the keyboard, so nothing will be changed."
            return 1
        fi
        case "$(answer_kind "$_ya")" in
            yes)  return 0 ;;
            no)   return 1 ;;
            none) echo " Please answer yes or no." ;;
            *)    echo " '$_ya' is not a yes or a no. Type yes or no." ;;
        esac
    done
    echo " No clear answer after $TOAST_ASK_TRIES tries, so nothing will be changed."
    return 1
}

# ask_number MAX "prompt" -> a number from 1 to MAX on stdout.
# Returns 1 when there is no usable answer, and 2 when the operator asked to
# stop. A numbered list needs a way out that is not a wrong number: without one
# the only exit from a disk picker is to pick a disk.
ask_number() {
    _nmax=$1
    _nt=0
    while [ "$_nt" -lt "$TOAST_ASK_TRIES" ]; do
        _nt=$((_nt + 1))
        printf '%s' "$2" >&2
        if ! read -r _na 2>/dev/null; then
            echo "" >&2
            echo " Nothing could be read from the keyboard." >&2
            return 1
        fi
        _na=$(toast_fold "$_na")
        case "$_na" in
            s|stop|cancel|quit|exit|q|abort|none|back)
                return 2 ;;
            '')          echo " Type a number between 1 and $_nmax, or 'stop' to stop." >&2; continue ;;
            *[!0-9]*)    echo " '$_na' is not a number. Type a number between 1 and $_nmax, or 'stop' to stop." >&2; continue ;;
        esac
        if [ "$_na" -ge 1 ] 2>/dev/null && [ "$_na" -le "$_nmax" ] 2>/dev/null; then
            printf '%s\n' "$_na"
            return 0
        fi
        echo " There is no number $_na in the list above. Choose between 1 and $_nmax." >&2
    done
    echo " No usable choice after $TOAST_ASK_TRIES tries." >&2
    return 1
}

# ask_option "prompt" "result=kw1,kw2,..." ... -> the chosen result on stdout.
# The number is just another keyword, so "2" and "replace" can select the same
# option and the operator never has to work out which form the script wants.
ask_option() {
    _op=$1
    shift
    _ot=0
    while [ "$_ot" -lt "$TOAST_ASK_TRIES" ]; do
        _ot=$((_ot + 1))
        printf '%s' "$_op" >&2
        if ! read -r _oa 2>/dev/null; then
            echo "" >&2
            echo " Nothing could be read from the keyboard." >&2
            return 1
        fi
        _oa=$(toast_fold "$_oa")
        if [ -z "$_oa" ]; then
            echo " Please type one of the choices listed above." >&2
            continue
        fi
        for _os in "$@"; do
            case ",${_os#*=}," in
                *",$_oa,"*) printf '%s\n' "${_os%%=*}"; return 0 ;;
            esac
        done
        echo " '$_oa' is not one of the choices above." >&2
    done
    echo " No clear answer after $TOAST_ASK_TRIES tries." >&2
    return 1
}

# --- powering off -----------------------------------------------------------
#
# ⛔ NEVER call bare `poweroff` from a live-boot session. It runs the orderly
# shutdown, which tries to unmount the medium and the squashfs overlay while the
# calling script and Clonezilla still reference them, and the console fills with
# squashfs I/O errors instead of powering off. Seen after a deploy on 2026-09-05.
#
# This is what Clonezilla itself does: ocs-functions parks the disks and then
# calls `systemctl $HALT_REBOOT_OPT poweroff`, where HALT_REBOOT_OPT defaults to
# -f precisely so the mounted medium is NOT unmounted first.
#
# ⛔ ONE COPY, on purpose. It used to be pasted into four scripts, which is four
# chances for one of them to drift back to a bare `poweroff`.
#
# TOAST_NO_POWEROFF exists for the test suite, which runs these scripts on the
# FOG server itself. Without it, exercising any stop path would power off the
# server. It is never set on a stick.
toast_poweroff() {
    sync
    if [ -n "${TOAST_NO_POWEROFF:-}" ]; then
        echo "TOAST_POWEROFF_SUPPRESSED"
        return 0
    fi
    command -v ocs-park-disks >/dev/null 2>&1 && ocs-park-disks >/dev/null 2>&1
    sync
    systemctl -f poweroff 2>/dev/null || poweroff -f 2>/dev/null || poweroff
}
