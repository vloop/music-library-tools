#!/usr/bin/env bash
# cdtheque_rename.sh — Renomme des fichiers (syntaxe perlexpr façon `rename`) et
# met à jour les références correspondantes dans les fichiers .cue (champ FILE)
# et .md5 (nom de fichier) du même répertoire.
#
# Usage: cdtheque_rename.sh 'perlexpr' fichier [fichier ...] [--apply] [--fix-title]
#
# Exemple :
#   cdtheque_rename.sh 's/Various Artists - //' *.flac
#
# Pour chaque fichier renommé :
#   - si c'est un .flac/.wav, le .cue du même répertoire dont le nom (sans
#     extension) commence par l'ancien nom de base (suivi éventuellement
#     d'un espace et d'un commentaire, ex: "Album commentaire.cue") voit son
#     champ FILE mis à jour
#   - tous les .md5 du répertoire référençant l'ancien nom voient la ligne
#     correspondante corrigée (le hash est conservé)
#   - le timestamp du .cue/.md5 modifié reçoit +5 minutes par rapport à son
#     timestamp d'origine, uniquement s'il a été effectivement modifié
#
# --fix-title applique la même perlexpr au champ TITLE de l'album (le TITLE
# global du .cue, avant le premier TRACK). Fonctionne aussi si un .cue est
# passé directement en argument, même sans renommage de fichier audio.
#
# Par défaut (sans --apply), les opérations sont simulées.
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
FIX_TITLE=false
PERLEXPR=""
FILES=()

for arg in "$@"; do
    case "$arg" in
        --apply)      APPLY=true ;;
        --fix-title)  FIX_TITLE=true ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            if [[ -z "$PERLEXPR" ]]; then
                PERLEXPR="$arg"
            else
                FILES+=("$arg")
            fi
            ;;
    esac
done

if [[ -z "$PERLEXPR" || ${#FILES[@]} -eq 0 ]]; then
    echo "Usage: $0 'perlexpr' fichier [fichier ...] [--apply]" >&2
    exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
    echo "ERROR: perl est requis pour ce script" >&2
    exit 1
fi

if ! $APPLY; then
    echo "=== MODE SIMULATION (ajouter --apply pour appliquer) ==="
fi

COUNT_PROCESSED=0
COUNT_MODIFIED=0
COUNT_ERRORS=0

# Calcule le nouveau nom via la perlexpr (comme `rename`)
apply_perlexpr() {
    local name="$1"
    perl -e '
        $_ = shift;
        eval shift;
        print $_;
    ' "$name" "$PERLEXPR"
}

# Échappe une chaîne pour usage dans une regex sed
escape_sed() {
    printf '%s' "$1" | sed 's/[[\.*^$()+?{}|/]/\\&/g'
}

# Met à jour le champ FILE dans le .cue correspondant, si trouvé, et si
# --fix-title est actif, applique aussi la perlexpr au TITLE de l'album.
# Cherche un .cue dont le nom (sans extension) commence par old_base
# (le nom audio sans extension), suivi éventuellement d'un espace + commentaire.
update_cue_reference() {
    local dir="$1" old_audio_name="$2" new_audio_name="$3"
    # Le .cue préexistant porte un nom dérivé du nom FINAL du fichier audio
    # (c'est généralement le nom du fichier déjà correctement nommé qui sert
    # de base au nom du .cue, éventuellement suivi d'un commentaire)
    local new_base="${new_audio_name%.*}"

    local cuefile=""
    mapfile -t candidates < <(find "$dir" -maxdepth 1 -name "*.cue" | sort)
    for c in "${candidates[@]}"; do
        local cbase
        cbase=$(basename "$c")
        cbase="${cbase%.cue}"
        if [[ "$cbase" == "$new_base" || "$cbase" == "$new_base "* ]]; then
            cuefile="$c"
            break
        fi
    done

    [[ -z "$cuefile" ]] && return 0

    update_cue_file "$cuefile" "$old_audio_name" "$new_audio_name"
}

# Applique les corrections (FILE et, si demandé, TITLE) à un .cue donné.
update_cue_file() {
    local cuefile="$1" old_audio_name="$2" new_audio_name="$3"

    local file_changed=false
    local title_changed=false
    local old_title="" new_title=""
    local old_file_value="" new_file_value=""

    if [[ -n "$old_audio_name" ]] && grep -qF "$old_audio_name" "$cuefile"; then
        file_changed=true
        old_file_value="$old_audio_name"
        new_file_value="$new_audio_name"
    fi

    if $FIX_TITLE; then
        # Extraire le TITLE de l'album : la première ligne TITLE avant le premier TRACK
        old_title=$(awk '
            /^[[:space:]]*TRACK[[:space:]]/ { exit }
            /^TITLE[[:space:]]+/ {
                sub(/^TITLE[[:space:]]+/, "")
                gsub(/\r$/, "")
                gsub(/^"|"$/, "")
                print
                exit
            }
        ' "$cuefile")
        if [[ -n "$old_title" ]]; then
            new_title=$(apply_perlexpr "$old_title")
            if [[ "$new_title" != "$old_title" ]]; then
                title_changed=true
            fi
        fi

        # Si FILE n'a pas déjà été traité via un fichier audio renommé,
        # appliquer aussi la perlexpr directement à la valeur de FILE,
        # pour rattraper les .cue dont le champ FILE est obsolète/incorrect
        # indépendamment de l'état réel des fichiers .flac sur disque.
        if ! $file_changed; then
            local cur_file_value
            cur_file_value=$(awk '
                /^FILE[[:space:]]+/ {
                    sub(/^FILE[[:space:]]+/, "")
                    sub(/[[:space:]]+[A-Z]+[[:space:]]*\r?$/, "")
                    gsub(/\r$/, "")
                    gsub(/^"|"$/, "")
                    print
                    exit
                }
            ' "$cuefile")
            if [[ -n "$cur_file_value" ]]; then
                local fixed_file_value
                fixed_file_value=$(apply_perlexpr "$cur_file_value")
                if [[ "$fixed_file_value" != "$cur_file_value" ]]; then
                    file_changed=true
                    old_file_value="$cur_file_value"
                    new_file_value="$fixed_file_value"
                fi
            fi
        fi
    fi

    if ! $file_changed && ! $title_changed; then
        return 0
    fi

    (( COUNT_PROCESSED++ )) || true

    local orig_ts
    orig_ts=$(stat -c '%Y' "$cuefile")

    if $APPLY; then
        local tmp
        tmp=$(mktemp)
        cp "$cuefile" "$tmp"

        if $file_changed; then
            local esc_old esc_new
            esc_old=$(escape_sed "$old_file_value")
            esc_new=$(escape_sed "$new_file_value")
            sed -i "s/${esc_old}/${esc_new}/g" "$tmp"
            echo "  MIS À JOUR (cue): '$(basename "$cuefile")' : FILE '$old_file_value' -> '$new_file_value'"
        fi

        if $title_changed; then
            local esc_old_t esc_new_t
            esc_old_t=$(escape_sed "$old_title")
            esc_new_t=$(escape_sed "$new_title")
            sed -i -E "0,/^TITLE[[:space:]]+\"?${esc_old_t}\"?[[:space:]]*\$/s//TITLE \"${esc_new_t}\"/" "$tmp"
            echo "  MIS À JOUR (cue): '$(basename "$cuefile")' : TITLE '$old_title' -> '$new_title'"
        fi

        cp "$tmp" "$cuefile"
        rm -f "$tmp"
        local new_ts=$(( orig_ts + 300 ))
        touch -d "@${new_ts}" "$cuefile"
    else
        $file_changed && echo "  [simulation] METTRAIT À JOUR (cue): '$(basename "$cuefile")' : FILE '$old_file_value' -> '$new_file_value'"
        $title_changed && echo "  [simulation] METTRAIT À JOUR (cue): '$(basename "$cuefile")' : TITLE '$old_title' -> '$new_title'"
    fi
    (( COUNT_MODIFIED++ )) || true
}

# Met à jour le nom de fichier référencé dans tous les .md5 du répertoire,
# en conservant le checksum tel quel.
update_md5_references() {
    local dir="$1" old_name="$2" new_name="$3"

    mapfile -t md5files < <(find "$dir" -maxdepth 1 -name "*.md5" | sort)
    for md5file in "${md5files[@]}"; do
        if ! grep -qF "$old_name" "$md5file"; then
            continue
        fi

        (( COUNT_PROCESSED++ )) || true

        local orig_ts
        orig_ts=$(stat -c '%Y' "$md5file")

        local esc_old esc_new
        esc_old=$(escape_sed "$old_name")
        esc_new=$(escape_sed "$new_name")

        if $APPLY; then
            local tmp
            tmp=$(mktemp)
            # Ne remplacer que dans la partie nom de fichier (après le hash et l'astérisque éventuel)
            sed -E "s/^([0-9a-fA-F]{32,128}[[:space:]]+\*?)${esc_old}\$/\1${esc_new}/" "$md5file" > "$tmp"
            cp "$tmp" "$md5file"
            rm -f "$tmp"
            local new_ts=$(( orig_ts + 300 ))
            touch -d "@${new_ts}" "$md5file"
            echo "  MIS À JOUR (md5): '$(basename "$md5file")' : '$old_name' -> '$new_name'"
        else
            echo "  [simulation] METTRAIT À JOUR (md5): '$(basename "$md5file")' : '$old_name' -> '$new_name'"
        fi
        (( COUNT_MODIFIED++ )) || true
    done
}

# ── Traitement des fichiers ────────────────────────────────────────────────────

for f in "${FILES[@]}"; do
    if [[ ! -e "$f" ]]; then
        echo "ERROR: fichier introuvable: '$f'"
        (( COUNT_ERRORS++ )) || true
        continue
    fi

    (( COUNT_PROCESSED++ )) || true

    dir=$(dirname "$f")
    base=$(basename "$f")
    new_base=$(apply_perlexpr "$base")
    renamed=false

    if [[ "$new_base" != "$base" ]]; then
        new_path="$dir/$new_base"

        if [[ -e "$new_path" ]]; then
            echo "CONFLIT: '$base' -> '$new_base' (cible déjà existante)"
            (( COUNT_ERRORS++ )) || true
            continue
        fi

        if $APPLY; then
            mv -- "$f" "$new_path"
            echo "RENOMMÉ: '$base' -> '$new_base'"
        else
            echo "[simulation] RENOMMERAIT: '$base' -> '$new_base'"
        fi
        (( COUNT_MODIFIED++ )) || true
        renamed=true
    fi

    # Mise à jour des références dans le .cue et les .md5, si fichier audio
    if [[ "$base" =~ \.(flac|wav|wave)$ ]]; then
        if $renamed || $FIX_TITLE; then
            update_cue_reference "$dir" "$base" "$new_base"
        fi
    fi

    # Si c'est directement un .cue (renommé ou non), appliquer --fix-title dessus
    if [[ "$base" =~ \.cue$ ]] && $FIX_TITLE; then
        # En --apply le fichier a déjà été déplacé vers new_path s'il a été renommé ;
        # en simulation il est toujours à son emplacement d'origine.
        target_cue="$f"
        $renamed && $APPLY && target_cue="$dir/$new_base"
        update_cue_file "$target_cue" "" ""
    fi

    if $renamed; then
        update_md5_references "$dir" "$base" "$new_base"
    fi
done

echo ""
echo "=== Bilan ==="
echo "  Traités  : $COUNT_PROCESSED"
echo "  Modifiés : $COUNT_MODIFIED"
echo "  Erreurs  : $COUNT_ERRORS"

if (( COUNT_ERRORS > 0 )); then
    exit 2
elif (( COUNT_MODIFIED > 0 )); then
    exit 1
else
    exit 0
fi
