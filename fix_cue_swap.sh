#!/usr/bin/env bash
# fix_cue_swap.sh — Échange TITLE et PERFORMER dans un bloc TRACK d'un fichier .cue
# quand le fichier .cue a le format erroné :
#     TITLE   "Evelyn Laye 1930 / One heavenly night"
#     PERFORMER "Early Film Recordings from Hollywood"
# au lieu de :
#     TITLE   "One heavenly night"
#     PERFORMER "Evelyn Laye 1930"
#
# Usage: fix_cue_swap.sh <fichier.cue> [OPTIONS]
#
# OPTIONS:
#   --use-separator SEP  Échange seulement si TITLE contient " SEP " (ex: / ou -)
#                        Par défaut (sans cette option) : échange inconditionnel
#                        Par défaut la partie AVANT SEP devient PERFORMER
#   --performer-last     Avec --use-separator : la partie APRÈS SEP devient PERFORMER
#                        (et la partie AVANT devient TITLE)
#   --keep-performer     (sans --use-separator) conserve le PERFORMER existant
#   --apply              Applique les modifications (sinon : simulation)
#   --help               Affiche cette aide
#
# Copyright (C) 2026  Marc Périlleux
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

APPLY=false
KEEP_PERFORMER=false
USE_SEPARATOR=false
SEPARATOR=""
PERFORMER_LAST=false
CUEFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)            APPLY=true ; shift ;;
        --keep-performer)   KEEP_PERFORMER=true ; shift ;;
        --performer-last)   PERFORMER_LAST=true ; shift ;;
        --use-separator)
            USE_SEPARATOR=true
            SEPARATOR="${2:?--use-separator requiert un séparateur (ex: / ou -)}"
            shift 2
            ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *.cue)  CUEFILE="$1" ; shift ;;
        *)
            # Argument sans -- : traité comme le fichier .cue
            if [[ -z "$CUEFILE" ]]; then
                CUEFILE="$1"
                shift
            else
                echo "Argument inconnu : '$1'" >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$CUEFILE" ]]; then
    echo "Usage: $0 <fichier.cue> [--use-separator SEP] [--performer-last] [--apply]" >&2
    exit 1
fi

if [[ ! -f "$CUEFILE" ]]; then
    echo "Fichier introuvable : '$CUEFILE'" >&2
    exit 1
fi

if $PERFORMER_LAST && ! $USE_SEPARATOR; then
    echo "ERREUR: --performer-last requiert --use-separator" >&2
    exit 1
fi

if ! $APPLY; then
    echo "=== MODE SIMULATION (ajouter --apply pour appliquer) ==="
fi

# ── Lecture et correction ──────────────────────────────────────────────────────

orig_ts=$(stat -c '%Y' "$CUEFILE")

in_track=false
changed=false
out_lines=()

buf_before=()
cur_title=""
cur_performer=""
cur_title_indent=""
cur_performer_indent=""
buf_after=()

flush_track() {
    local do_swap=false
    local new_title="$cur_title"
    local new_performer="$cur_performer"

    if $USE_SEPARATOR; then
        # Échange conditionnel : seulement si TITLE contient " SEP "
        local sep_pattern="${SEPARATOR}"
        if [[ "$cur_title" == *"${sep_pattern}"* ]]; then
            if $PERFORMER_LAST; then
                # Partie APRÈS le séparateur -> PERFORMER, partie AVANT -> TITLE
                new_title="${cur_title%${sep_pattern}*}"
                new_performer="${cur_title##*${sep_pattern}}"
            else
                # Partie AVANT le séparateur -> PERFORMER (défaut)
                new_performer="${cur_title%%${sep_pattern}*}"
                new_title="${cur_title#*${sep_pattern}}"
            fi
            do_swap=true
        fi
    else
        # Échange inconditionnel TITLE <-> PERFORMER
        new_title="$cur_performer"
        new_performer="$cur_title"
        do_swap=true
    fi

    if $do_swap && [[ "$new_performer" != "$cur_performer" || "$new_title" != "$cur_title" ]]; then
        changed=true
        echo "  TITRE    : \"$cur_title\"  ->  \"$new_title\""
        echo "  PERFORMER: \"$cur_performer\"  ->  \"$new_performer\""
    fi

    for l in "${buf_before[@]}"; do out_lines+=("$l"); done
    if $do_swap; then
        out_lines+=("${cur_title_indent}TITLE \"${new_title}\"")
        [[ -n "$cur_performer_indent" ]] && out_lines+=("${cur_performer_indent}PERFORMER \"${new_performer}\"")
    else
        [[ -n "$cur_title_indent" ]]     && out_lines+=("${cur_title_indent}TITLE \"${cur_title}\"")
        [[ -n "$cur_performer_indent" ]] && out_lines+=("${cur_performer_indent}PERFORMER \"${cur_performer}\"")
    fi
    for l in "${buf_after[@]}"; do out_lines+=("$l"); done

    buf_before=()
    buf_after=()
    cur_title=""
    cur_performer=""
    cur_title_indent=""
    cur_performer_indent=""
}

state="BEFORE_TITLE"
mapfile -t lines < "$CUEFILE"

for line in "${lines[@]}"; do
    line="${line//$'\r'/}"

    if [[ "$line" =~ ^([[:space:]]*)TRACK[[:space:]]+[0-9]+[[:space:]]+AUDIO ]]; then
        $in_track && flush_track
        in_track=true
        state="BEFORE_TITLE"
        buf_before+=("$line")
        continue
    fi

    if ! $in_track; then
        out_lines+=("$line")
        continue
    fi

    if [[ "$line" =~ ^([[:space:]]*)TITLE[[:space:]]+(.+)[[:space:]]*$ && "$state" == "BEFORE_TITLE" ]]; then
        cur_title_indent="${BASH_REMATCH[1]}"
        cur_title=$(printf '%s' "${BASH_REMATCH[2]}" | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
        state="AFTER_TITLE"

    elif [[ "$line" =~ ^([[:space:]]*)PERFORMER[[:space:]]+(.+)[[:space:]]*$ && "$state" == "AFTER_TITLE" ]]; then
        cur_performer_indent="${BASH_REMATCH[1]}"
        cur_performer=$(printf '%s' "${BASH_REMATCH[2]}" | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
        state="AFTER_PERFORMER"

    elif [[ "$state" == "BEFORE_TITLE" ]]; then
        buf_before+=("$line")
    else
        buf_after+=("$line")
    fi
done

$in_track && flush_track

# ── Résultat ──────────────────────────────────────────────────────────────────

if ! $changed; then
    if $USE_SEPARATOR; then
        echo "Aucune piste avec TITLE contenant '${SEPARATOR}' trouvée dans '$(basename "$CUEFILE")'."
    else
        echo "Aucune piste à échanger trouvée dans '$(basename "$CUEFILE")'."
    fi
    exit 0
fi

if $APPLY; then
    new_ts=$(( orig_ts + 300 ))
    tmp=$(mktemp)
    printf '%s\n' "${out_lines[@]}" > "$tmp"
    cp "$tmp" "$CUEFILE"
    rm -f "$tmp"
    touch -d "@${new_ts}" "$CUEFILE"
    echo "MODIFIÉ: '$(basename "$CUEFILE")' (timestamp original + 5 min)"
else
    echo ""
    echo "[simulation] Le fichier '$(basename "$CUEFILE")' serait modifié comme indiqué ci-dessus."
fi
