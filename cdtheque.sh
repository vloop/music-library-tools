#!/usr/bin/env bash
# cdtheque.sh — Outil de gestion de la cdthèque

# Usage: cdtheque.sh [OPTIONS] [fichier ...]
#        Sans fichier explicite, s'applique à tous les fichiers du répertoire courant.
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

# ─── Constantes de code retour (bits) ────────────────────────────────────────
readonly RC_MODIFIED=1   # bit 0 : modification effective ou simulée
readonly RC_ERROR=2      # bit 1 : erreur (exclut RC_MODIFIED)
readonly RC_WARNING=4    # bit 2 : avertissement

# ─── Compteurs et listes globaux ─────────────────────────────────────────────
COUNT_PROCESSED=0
COUNT_MODIFIED=0
COUNT_ERRORS=0
COUNT_WARNINGS=0
FILES_WITH_ERRORS=()
FILES_WITH_WARNINGS=()

# Enregistre un fichier dans la liste erreurs/warnings selon le rc retourné
# Usage: register_file_rc <filename> <rc>
register_file_rc() {
    local fname="$1" frc="$2"
    (( frc & RC_ERROR   )) && FILES_WITH_ERRORS+=("$fname")   || true
    (( frc & RC_WARNING )) && FILES_WITH_WARNINGS+=("$fname") || true
}

APPLY=false

# ─── Interruption propre ──────────────────────────────────────────────────────
_interrupted=false
_cleanup() {
    if ! $_interrupted; then
        _interrupted=true
        echo ""
        echo "(interrompu)"
        echo ""
        echo "=== Bilan partiel ==="
        echo "  Traités       : $COUNT_PROCESSED"
        echo "  Modifiés      : $COUNT_MODIFIED"
        echo "  Avertissements: $COUNT_WARNINGS"
        echo "  Erreurs       : $COUNT_ERRORS"
        if (( ${#FILES_WITH_ERRORS[@]} > 0 )); then
            echo "  Fichiers en erreur:"
            for f in "${FILES_WITH_ERRORS[@]}"; do echo "    $f"; done
        fi
        if (( ${#FILES_WITH_WARNINGS[@]} > 0 )); then
            echo "  Fichiers avec avertissements:"
            for f in "${FILES_WITH_WARNINGS[@]}"; do echo "    $f"; done
        fi
    fi
    exit 130
}
trap '_cleanup' INT TERM

# ─── Aide ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: cdtheque.sh [OPTIONS] [fichier ...]

Outil de gestion de la cdthèque. S'applique au répertoire courant,
ou aux fichiers explicitement listés en fin de ligne de commande.

OPTIONS:
  --fix-names        Renomme fichiers et sous-répertoires de niveau 1
  --fix-md5          Corrige le contenu des fichiers .md5
  --check-md5        Vérifie les checksums des fichiers .md5 (indépendant de --fix-md5)
  --fix-cue          Corrige le contenu des fichiers .cue (signale aussi les INDEX anormaux)
  --fix-indexes      Corrige les INDEX anormaux dans les .cue (implique --fix-cue)
  --fix-folder       Applique le timestamp du fichier le plus récent au répertoire
  --mp3 <dest>       Convertit les pistes d'un .cue en mp3 vers <dest>
  --mp3-sub <dest>   Copie/convertit les sous-dossiers vers <dest>
  --mp3-quality N    Qualité VBR ffmpeg de 0 (meilleur) à 9 (pire), défaut: 2
  --keep-performer   Inclut le performer dans le nom des mp3 (par défaut omis)
                     et ne supprime pas le préfixe NomRep dans --fix-names
  --compil-prefix P  Préfixe identifiant les compilations (défaut: "0 Compil")
  --apply            Applique réellement les modifications (sinon: simulation)
  --help             Affiche cette aide

Par défaut (sans --apply), les opérations sont simulées.
EOF
}

# ─── Détection et conversion d'encodage ───────────────────────────────────────

# Détecte l'encodage d'une chaîne brute (bytes).
# Renvoie: utf-8, cp1252, ascii, ou unknown
detect_encoding() {
    local file="$1"
    # Utilise file(1) pour détecter
    local info
    info=$(file -b --mime-encoding "$file" 2>/dev/null || true)
    case "$info" in
        us-ascii)       echo "ascii"  ;;
        utf-8)          echo "utf-8"  ;;
        iso-8859-*)     echo "cp1252" ;;
        unknown-8bit|binary)
            # Tentative de décodage cp1252
            if iconv -f cp1252 -t utf-8 "$file" >/dev/null 2>&1; then
                echo "cp1252"
            else
                echo "unknown"
            fi
            ;;
        *)
            # Tente utf-8 strict, sinon cp1252
            if iconv -f utf-8 -t utf-8 "$file" >/dev/null 2>&1; then
                echo "utf-8"
            elif iconv -f cp1252 -t utf-8 "$file" >/dev/null 2>&1; then
                echo "cp1252"
            else
                echo "unknown"
            fi
            ;;
    esac
}

# Convertit une chaîne (passée en stdin ou dans une variable) de l'encodage
# détecté vers utf-8. Retourne la chaîne convertie sur stdout.
convert_string_to_utf8() {
    local str="$1"
    local enc="$2"   # ascii, utf-8, cp1252
    case "$enc" in
        ascii|utf-8)  printf '%s' "$str" ;;
        cp1252)       printf '%s' "$str" | iconv -f cp1252 -t utf-8 ;;
        *)            printf '%s' "$str" ;;
    esac
}

# Convertit un fichier entier vers utf-8 (en place dans un tmpfile).
# Renvoie le chemin du fichier converti (ou l'original si pas de changement).
convert_file_to_utf8() {
    local src="$1"
    local enc
    enc=$(detect_encoding "$src")
    if [[ "$enc" == "unknown" ]]; then
        echo "ERROR: encodage non reconnu pour '$src'" >&2
        return 2
    fi
    local tmp
    tmp=$(mktemp)
    if [[ "$enc" == "cp1252" ]]; then
        iconv -f cp1252 -t utf-8 "$src" > "$tmp"
    else
        cp "$src" "$tmp"
    fi
    echo "$tmp"
}

# ─── Règles de renommage ──────────────────────────────────────────────────────

# Calcule le nouveau nom de fichier selon les règles.
# Arguments: dirname basename
# Affiche le nouveau basename sur stdout (identique si pas de changement).
# Utilise les variables globales KEEP_PERFORMER et COMPIL_PREFIX.
compute_new_name() {
    local dir="$1"
    local base="$2"
    local dirname_only
    dirname_only=$(basename "$dir")

    local new="$base"

    if [[ "$dirname_only" == "${COMPIL_PREFIX}"* ]]; then
        # Supprimer "Various Artists - ", "Various artists - ", "Various - ",
        # "VA - ", "Artistes divers - " en début de nom (insensible à la casse
        # pour "artists")
        new=$(printf '%s' "$new" | \
            sed -E 's/^(Various Artists|Various artists|Various|VA|Artistes divers) - //i')
    elif ! $KEEP_PERFORMER; then
        # Supprimer "NomRep - " si la partie avant " - " correspond exactement
        # au nom du répertoire
        local escaped_dir
        escaped_dir=$(printf '%s' "$dirname_only" | sed 's/[[\.*^$()+?{}|]/\\&/g')
        new=$(printf '%s' "$new" | \
            sed -E "s/^${escaped_dir} - //")
    fi

    printf '%s' "$new"
}

# ─── 1. fix_names ─────────────────────────────────────────────────────────────
fix_names() {
    local curdir="$PWD"
    local rc=0

    # Collecte fichiers + sous-répertoires de niveau 1
    mapfile -t entries < <(find "$curdir" -maxdepth 1 -mindepth 1 \
        \( -type f -o -type d \) | sort)

    for entry in "${entries[@]}"; do
        local base new enc src_enc
        base=$(basename "$entry")
        local dir
        dir=$(dirname "$entry")

        # Détecte l'encodage du nom (en traitant le nom comme un fichier fictif
        # via une chaîne tmpfile)
        local tmp_name
        tmp_name=$(mktemp)
        printf '%s' "$base" > "$tmp_name"
        src_enc=$(detect_encoding "$tmp_name")
        rm -f "$tmp_name"

        if [[ "$src_enc" == "unknown" ]]; then
            echo "ERROR: encodage non reconnu pour '$base'"
            (( COUNT_ERRORS++ )) || true
            (( COUNT_PROCESSED++ )) || true
            (( rc |= RC_ERROR )) || true
            continue
        fi

        # Conversion utf-8 du nom
        local base_utf8
        base_utf8=$(convert_string_to_utf8 "$base" "$src_enc")

        # Règles de renommage
        local new_name
        new_name=$(compute_new_name "$curdir" "$base_utf8")

        (( COUNT_PROCESSED++ )) || true

        if [[ "$new_name" != "$base" ]]; then
            local new_path="$dir/$new_name"
            if [[ -e "$new_path" && "$new_path" != "$entry" ]]; then
                echo "CONFLIT: '$base' -> '$new_name' (cible déjà existante)"
                (( COUNT_ERRORS++ )) || true
                (( rc |= RC_ERROR )) || true
                continue
            fi
            if $APPLY; then
                mv -- "$entry" "$new_path"
                echo "RENOMMÉ: '$base' -> '$new_name'"
            else
                echo "[simulation] RENOMMERAIT: '$base' -> '$new_name'"
            fi
            (( COUNT_MODIFIED++ )) || true
            (( rc |= RC_MODIFIED )) || true
        fi
    done

    # Erreur exclut modification
    (( rc & RC_ERROR )) && (( rc &= ~RC_MODIFIED )) || true
    return $rc
}

# ─── Utilitaire timestamp ──────────────────────────────────────────────────────

# Retourne le timestamp Unix d'un fichier
file_mtime() {
    stat -c '%Y' "$1"
}

# Ajoute 5 minutes (300 s) au timestamp d'origine et l'applique au fichier.
# Le timestamp d'origine DOIT être capturé avant toute écriture sur le fichier.
# Usage: add5min_timestamp <file> <orig_ts>
add5min_timestamp() {
    local file="$1"
    local orig_ts="$2"
    local new_ts=$(( orig_ts + 300 ))
    touch -d "@${new_ts}" "$file"
}

# ─── 2. fix_md5 ───────────────────────────────────────────────────────────────
fix_md5() {
    local md5file="$1"
    local new_filename="$2"   # nouveau nom du .md5 lui-même (peut être identique)
    local with_check="${3:-false}"

    local curdir="$PWD"
    local rc=0
    local modified=false

    # Détecter et convertir le fichier entier en utf-8
    local tmp_content
    tmp_content=$(convert_file_to_utf8 "$md5file")
    if [[ $? -ne 0 ]]; then
        (( COUNT_ERRORS++ )) || true
        return $RC_ERROR
    fi

    local out_lines=()
    local changed=false

    mapfile -t lines < "$tmp_content"
    rm -f "$tmp_content"

    for line in "${lines[@]}"; do
        line="${line//$'\r'/}"
        # Format: <checksum><séparateur><*| ><filename>
        if [[ "$line" =~ ^([0-9a-fA-F]{32,128})[[:space:]]+(\*?)(.+)$ ]]; then
            local cksum="${BASH_REMATCH[1]}"
            local star="${BASH_REMATCH[2]}"
            local fname="${BASH_REMATCH[3]}"
            local sep=" "

            local new_fname
            new_fname=$(compute_new_name "$curdir" "$fname")

            if [[ "$new_fname" != "$fname" || "$star" == "*" ]]; then
                changed=true
            fi

            # Vérifier existence du fichier référencé
            if [[ ! -e "$curdir/$new_fname" ]]; then
                echo "ATTENTION: fichier référencé introuvable: '$new_fname' (dans $md5file)"
                (( COUNT_ERRORS++ )) || true
                (( rc |= RC_ERROR )) || true
            fi

            # Vérification checksum si demandée
            if [[ "$with_check" == "true" && -e "$curdir/$new_fname" ]]; then
                echo -n "  Vérification: '$new_fname' ... "
                local computed
                computed=$(md5sum "$curdir/$new_fname" | awk '{print $1}')
                if [[ "$computed" == "$cksum" ]]; then
                    echo "OK"
                else
                    echo "ERREUR"
                    echo "ERROR: checksum invalide pour '$new_fname' dans '$md5file'"
                    (( COUNT_ERRORS++ )) || true
                    (( rc |= RC_ERROR )) || true
                fi
            fi

            out_lines+=("${cksum}${sep}${new_fname}")
        else
            out_lines+=("$line")
        fi
    done

    (( COUNT_PROCESSED++ )) || true

    if $changed; then
        local rename_conflict=false
        if [[ "$new_filename" != "$md5file" && -e "$new_filename" ]]; then
            rename_conflict=true
            echo "CONFLIT: '$(basename "$md5file")' devrait être renommé en '$(basename "$new_filename")' mais ce fichier existe déjà"
            echo "         Le fichier sera conservé sous son nom d'origine avec le contenu corrigé"
            (( COUNT_ERRORS++ )) || true
            (( rc |= RC_ERROR )) || true
        fi

        if $APPLY; then
            local orig_ts
            orig_ts=$(file_mtime "$md5file")
            local tmp_out
            tmp_out=$(mktemp)
            printf '%s\n' "${out_lines[@]}" > "$tmp_out"
            cp "$tmp_out" "$md5file"
            rm -f "$tmp_out"
            add5min_timestamp "$md5file" "$orig_ts"
            if [[ "$new_filename" != "$md5file" ]] && ! $rename_conflict; then
                mv -- "$md5file" "$new_filename"
                echo "MODIFIÉ+RENOMMÉ: '$(basename "$md5file")' -> '$(basename "$new_filename")'"
            else
                echo "MODIFIÉ: '$(basename "$md5file")'"
            fi
        else
            if $rename_conflict; then
                echo "[simulation] MODIFIERAIT le contenu de: '$(basename "$md5file")' (sans renommage)"
            else
                echo "[simulation] MODIFIERAIT: '$(basename "$md5file")'"
            fi
            for l in "${out_lines[@]}"; do echo "  $l"; done
        fi
        (( COUNT_MODIFIED++ )) || true
        (( rc |= RC_MODIFIED )) || true
    fi

    # Erreur exclut modification
    (( rc & RC_ERROR )) && (( rc &= ~RC_MODIFIED )) || true
    return $rc
}

# ─── Utilitaire timecode ──────────────────────────────────────────────────────

# Normalise un timecode MM:SS:FF :
# - remplace le dernier séparateur point par deux-points (32:36.58 -> 32:36:58)
# - ajoute les zéros manquants (9:24:61 -> 09:24:61)
normalize_timecode() {
    local tc="$1"
    # Remplacer un point séparateur par deux-points
    tc="${tc/./\:}"
    local mm ss ff
    IFS=: read -r mm ss ff <<< "$tc"
    printf '%02d:%02d:%02d' "$(( 10#$mm ))" "$(( 10#$ss ))" "$(( 10#$ff ))"
}

# Analyse les INDEX d'un tableau de lignes (passé par nom) et signale les anomalies.
# Si fix=true, corrige aussi dans le tableau out_lines (passé par nom).
# Retourne 0=ok, 1=anomalie signalée, 2=anomalie corrigée
check_indexes() {
    local -n _lines_ref="$1"
    local -n _out_ref="$2"
    local cuename="$3"
    local fix="$4"   # true ou false
    local rc=0
    local n=${#_lines_ref[@]}

    for (( i=0; i<n; i++ )); do
        local line="${_lines_ref[$i]//$'\r'/}"
        if [[ "$line" =~ ^([[:space:]]*)INDEX[[:space:]]+([0-9]+)[[:space:]]+([0-9:.]+)[[:space:]]*$ ]]; then
            local indent="${BASH_REMATCH[1]}"
            local idx_num="${BASH_REMATCH[2]}"
            local timecode="${BASH_REMATCH[3]}"
            local new_num="$idx_num"
            local new_tc
            new_tc=$(normalize_timecode "$timecode")

            # INDEX 00 sans INDEX 01 dans le même bloc TRACK ?
            if [[ "$idx_num" == "00" ]]; then
                local has_index01=false
                for (( j=i+1; j<n; j++ )); do
                    local next="${_lines_ref[$j]//$'\r'/}"
                    [[ "$next" =~ ^[[:space:]]*TRACK[[:space:]] ]] && break
                    [[ "$next" =~ ^[[:space:]]*INDEX[[:space:]]+01[[:space:]] ]] && { has_index01=true; break; }
                done
                $has_index01 || new_num="01"
            fi

            local new_line="${indent}INDEX ${new_num} ${new_tc}"
            if [[ "$new_line" != "$line" ]]; then
                if $fix; then
                    _out_ref[$i]="$new_line"
                    echo "  INDEX corrigé: '$(echo "$line" | sed 's/^[[:space:]]*//')' -> 'INDEX ${new_num} ${new_tc}' (dans $(basename "$cuename"))"
                    (( COUNT_MODIFIED++ )) || true
                    (( rc |= RC_MODIFIED )) || true
                else
                    echo "  ATTENTION INDEX: '$(echo "$line" | sed 's/^[[:space:]]*//')' -> devrait être 'INDEX ${new_num} ${new_tc}' (dans $(basename "$cuename"))"
                    (( COUNT_WARNINGS++ )) || true
                    (( rc |= RC_WARNING )) || true
                fi
            fi
        fi
    done
    return $rc
}

# ─── 3. fix_cue ───────────────────────────────────────────────────────────────
fix_cue() {
    local cuefile="$1"
    local new_filename="$2"

    local curdir="$PWD"
    local rc=0

    # Détecter l'encodage AVANT conversion
    local orig_enc
    orig_enc=$(detect_encoding "$cuefile")
    if [[ "$orig_enc" == "unknown" ]]; then
        echo "ERROR: encodage non reconnu pour '$cuefile'"
        (( COUNT_ERRORS++ )) || true
        return $RC_ERROR
    fi

    # Convertir le fichier en utf-8 dans un tmpfile (toujours, pour lire proprement)
    local tmp_content
    tmp_content=$(mktemp)
    if [[ "$orig_enc" == "cp1252" ]]; then
        iconv -f cp1252 -t utf-8 "$cuefile" > "$tmp_content"
    else
        cp "$cuefile" "$tmp_content"
    fi

    local out_lines=()
    local content_changed=false
    # La conversion UTF-8 n'est un changement que si --fix-cue est actif
    [[ "$orig_enc" == "cp1252" ]] && $DO_FIX_CUE && content_changed=true

    mapfile -t lines < "$tmp_content"
    rm -f "$tmp_content"

    for line in "${lines[@]}"; do
        line="${line//$'\r'/}"
        local new_line="$line"

        if $DO_FIX_CUE; then
            # Champ FILE — format : FILE "nom du fichier" TYPE
            # ou sans guillemets :  FILE nom.flac WAVE
            if [[ "$line" =~ ^(FILE[[:space:]]+\")(.+)(\"[[:space:]]+[A-Z]+[[:space:]]*)$ ]]; then
                local prefix="${BASH_REMATCH[1]}"
                local fname="${BASH_REMATCH[2]}"
                local suffix="${BASH_REMATCH[3]}"
                local new_fname
                new_fname=$(compute_new_name "$curdir" "$fname")
                if [[ "$new_fname" != "$fname" ]]; then
                    content_changed=true
                    new_line="${prefix}${new_fname}${suffix}"
                fi
                if [[ ! -e "$curdir/$new_fname" ]]; then
                    echo "ERROR: fichier audio introuvable: '$new_fname' (dans $(basename "$cuefile"))"
                    (( COUNT_ERRORS++ )) || true
                    (( rc |= RC_ERROR )) || true
                fi

            elif [[ "$line" =~ ^(FILE[[:space:]]+)([^\"]+[[:space:]]+)([A-Z]+[[:space:]]*)$ ]]; then
                local prefix="${BASH_REMATCH[1]}"
                local rest="${BASH_REMATCH[2]}"
                local suffix="${BASH_REMATCH[3]}"
                local fname
                fname=$(echo "$rest" | sed 's/[[:space:]]*$//')
                local new_fname
                new_fname=$(compute_new_name "$curdir" "$fname")
                if [[ "$new_fname" != "$fname" ]]; then
                    content_changed=true
                    new_line="${prefix}${new_fname} ${suffix}"
                fi
                if [[ ! -e "$curdir/$new_fname" ]]; then
                    echo "ERROR: fichier audio introuvable: '$new_fname' (dans $(basename "$cuefile"))"
                    (( COUNT_ERRORS++ )) || true
                    (( rc |= RC_ERROR )) || true
                fi
            fi

            # Dans un répertoire compil, normaliser le PERFORMER "Various*" / "VA" etc.
            local dirname_only
            dirname_only=$(basename "$curdir")
            if [[ "$dirname_only" == "${COMPIL_PREFIX}"* ]]; then
                if [[ "$new_line" =~ ^([[:space:]]*PERFORMER[[:space:]]+\"?)(Various Artists|Various artists|Various|VA|Artistes divers)(\"?[[:space:]]*)$ ]]; then
                    local perf_prefix="${BASH_REMATCH[1]}"
                    local perf_matched="${BASH_REMATCH[2]}"
                    local perf_suffix="${BASH_REMATCH[3]}"
                    if [[ "$perf_matched" != "Various Artists" ]]; then
                        new_line="${perf_prefix}Various Artists${perf_suffix}"
                        content_changed=true
                    fi
                fi
            fi
        fi

        out_lines+=("$new_line")
    done

    (( COUNT_PROCESSED++ )) || true

    # Avertissement si TITLE de l'album == PERFORMER (erreur fréquente)
    if $DO_FIX_CUE; then
        local album_title_val="" album_performer_val=""
        for chk_line in "${out_lines[@]}"; do
            chk_line="${chk_line//$'\r'/}"
            [[ "$chk_line" =~ ^[[:space:]]*TRACK[[:space:]] ]] && break
            if [[ "$chk_line" =~ ^TITLE[[:space:]]+(.*) ]]; then
                album_title_val=$(printf '%s' "${BASH_REMATCH[1]}" | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
            fi
            if [[ "$chk_line" =~ ^PERFORMER[[:space:]]+(.*) ]]; then
                album_performer_val=$(printf '%s' "${BASH_REMATCH[1]}" | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
            fi
        done
        if [[ -n "$album_title_val" && -n "$album_performer_val" \
              && "$album_title_val" == "$album_performer_val" ]]; then
            echo "ATTENTION: TITLE == PERFORMER ('$album_title_val') dans $(basename "$cuefile")"
            (( COUNT_WARNINGS++ )) || true
            (( rc |= RC_WARNING )) || true
        fi

        # Avertissements au niveau des pistes : TITLE==PERFORMER et TrackNN
        local trk_num="" trk_title="" trk_performer="" in_trk=false
        for chk_line in "${out_lines[@]}"; do
            chk_line="${chk_line//$'\r'/}"
            if [[ "$chk_line" =~ ^[[:space:]]*TRACK[[:space:]]+([0-9]+)[[:space:]] ]]; then
                local matched_trk_num="${BASH_REMATCH[1]}"
                # Vérifier la piste précédente avant de passer à la suivante
                if $in_trk; then
                    if [[ -n "$trk_title" && -n "$trk_performer" \
                          && "$trk_title" == "$trk_performer" \
                          && ! "$trk_title" =~ ^[Tt]rack[[:space:]]*[0-9]+$ ]]; then
                        echo "ATTENTION: piste $trk_num : TITLE == PERFORMER ('$trk_title') dans $(basename "$cuefile")"
                        (( COUNT_WARNINGS++ )) || true
                        (( rc |= RC_WARNING )) || true
                    fi
                    if [[ "$trk_title" =~ ^[Tt]rack[[:space:]]*[0-9]+$ ]]; then
                        echo "ATTENTION: piste $trk_num : TITLE générique ('$trk_title') dans $(basename "$cuefile")"
                        (( COUNT_WARNINGS++ )) || true
                        (( rc |= RC_WARNING )) || true
                    fi
                fi
                trk_num="$matched_trk_num"
                trk_title=""
                trk_performer=""
                in_trk=true
            elif $in_trk && [[ "$chk_line" =~ ^[[:space:]]*TITLE[[:space:]]+(.*) ]]; then
                trk_title=$(printf '%s' "${BASH_REMATCH[1]:-}" | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
            elif $in_trk && [[ "$chk_line" =~ ^[[:space:]]*PERFORMER[[:space:]]+(.*) ]]; then
                trk_performer=$(printf '%s' "${BASH_REMATCH[1]:-}" | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
            fi
        done
        # Vérifier la dernière piste
        if $in_trk; then
            if [[ -n "$trk_title" && -n "$trk_performer" \
                  && "$trk_title" == "$trk_performer" \
                  && ! "$trk_title" =~ ^[Tt]rack[[:space:]]*[0-9]+$ ]]; then
                echo "ATTENTION: piste $trk_num : TITLE == PERFORMER ('$trk_title') dans $(basename "$cuefile")"
                (( COUNT_WARNINGS++ )) || true
                (( rc |= RC_WARNING )) || true
            fi
            if [[ "$trk_title" =~ ^[Tt]rack[[:space:]]*[0-9]+$ ]]; then
                echo "ATTENTION: piste $trk_num : TITLE générique ('$trk_title') dans $(basename "$cuefile")"
                (( COUNT_WARNINGS++ )) || true
                (( rc |= RC_WARNING )) || true
            fi
        fi
    fi

    # Signalement (et correction si --fix-indexes) des INDEX anormaux
    local idx_rc=0
    check_indexes lines out_lines "$cuefile" "$DO_FIX_INDEXES" || idx_rc=$?
    (( idx_rc & RC_MODIFIED )) && content_changed=true || true
    (( rc |= idx_rc )) || true

    if $content_changed; then
        if $APPLY; then
            local orig_ts
            orig_ts=$(file_mtime "$cuefile")
            local tmp_out
            tmp_out=$(mktemp)
            printf '%s\n' "${out_lines[@]}" > "$tmp_out"
            cp "$tmp_out" "$cuefile"
            rm -f "$tmp_out"
            add5min_timestamp "$cuefile" "$orig_ts"
            if [[ "$new_filename" != "$cuefile" ]]; then
                mv -- "$cuefile" "$new_filename"
                echo "MODIFIÉ+RENOMMÉ: '$(basename "$cuefile")' -> '$(basename "$new_filename")'"
            else
                echo "MODIFIÉ: '$(basename "$cuefile")'"
            fi
        else
            echo "[simulation] MODIFIERAIT: '$(basename "$cuefile")'"
            for l in "${out_lines[@]}"; do
                [[ "$l" =~ ^FILE ]] && echo "  $l"
            done
        fi
        (( COUNT_MODIFIED++ )) || true
        (( rc |= RC_MODIFIED )) || true
    fi

    # Erreur exclut modification
    (( rc & RC_ERROR )) && (( rc &= ~RC_MODIFIED )) || true
    return $rc
}

# ─── 4. fix_folder ────────────────────────────────────────────────────────────
fix_folder() {
    local curdir="$PWD"

    # Répertoire courant lui-même
    apply_folder_timestamp "$curdir"

    # Sous-répertoires de niveau 1
    mapfile -t subdirs < <(find "$curdir" -maxdepth 1 -mindepth 1 -type d | sort)
    for subdir in "${subdirs[@]}"; do
        apply_folder_timestamp "$subdir"
    done
}

apply_folder_timestamp() {
    local dir="$1"
    local newest_ts=0

    mapfile -t files < <(find "$dir" -maxdepth 1 -mindepth 1 -type f)
    for f in "${files[@]}"; do
        local ts
        ts=$(file_mtime "$f")
        (( ts > newest_ts )) && newest_ts=$ts
    done

    if (( newest_ts > 0 )); then
        local current_ts
        current_ts=$(file_mtime "$dir")
        if (( newest_ts != current_ts )); then
            (( COUNT_PROCESSED++ )) || true
            if $APPLY; then
                touch -d "@${newest_ts}" "$dir"
                echo "TIMESTAMP: '$dir' -> $(date -d @${newest_ts} '+%Y-%m-%d %H:%M:%S')"
                (( COUNT_MODIFIED++ )) || true
            else
                echo "[simulation] TIMESTAMP: '$dir' -> $(date -d @${newest_ts} '+%Y-%m-%d %H:%M:%S')"
                (( COUNT_MODIFIED++ )) || true
            fi
        fi
    fi
}

# ─── 5a. create_mp3 (depuis un fichier .cue) ──────────────────────────────────

# Supprime les guillemets entourants d'une valeur cue et le \r éventuel
strip_cue_quotes() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^"\(.*\)"$/\1/'
}

create_mp3() {
    local cuefile="$1"
    local destination="$2"

    local curdir="$PWD"

    # ── Parsing ligne à ligne du cue ──────────────────────────────────────────
    # Champs globaux (avant le premier TRACK)
    local album_title="" global_performer="" date_tag="" audio_file=""
    # Tableaux par piste
    local tracks=()      # numéros (chaîne, ex: "01", "08")
    local titles=()      # TITLE de chaque piste
    local performers=()  # PERFORMER de chaque piste (peut être vide)
    local indices=()      # INDEX 01 de chaque piste
    local indices_00=()   # INDEX 00 de chaque piste (peut être vide)

    local in_track=false
    local cur_track="" cur_title="" cur_performer="" cur_index="" cur_index_00=""

    mapfile -t cue_lines < "$cuefile"

    for cline in "${cue_lines[@]}"; do
        # Supprime le \r éventuel (fichiers CRLF) et l'indentation
        cline="${cline//$'\r'/}"
        local stripped="${cline#"${cline%%[![:space:]]*}"}"

        if [[ "$stripped" =~ ^TRACK[[:space:]]+([0-9]+)[[:space:]]+AUDIO ]]; then
            # Sauvegarder la piste précédente si on en avait une
            if $in_track && [[ -n "$cur_track" ]]; then
                tracks+=("$cur_track")
                titles+=("$cur_title")
                performers+=("$cur_performer")
                indices+=("$cur_index")
                indices_00+=("$cur_index_00")
            fi
            cur_track="${BASH_REMATCH[1]}"
            cur_title=""
            cur_performer=""
            cur_index=""
            cur_index_00=""
            in_track=true

        elif [[ "$stripped" =~ ^FILE[[:space:]]+\"(.+)\"[[:space:]]+[A-Z]+ ]]; then
            audio_file="${BASH_REMATCH[1]}"

        elif [[ "$stripped" =~ ^FILE[[:space:]]+(.+)[[:space:]]+[A-Z]+$ ]] && [[ -z "$audio_file" ]]; then
            audio_file="${BASH_REMATCH[1]}"

        elif [[ "$stripped" =~ ^REM[[:space:]]+DATE[[:space:]]+([0-9]+) ]]; then
            date_tag="${BASH_REMATCH[1]}"

        elif [[ "$stripped" =~ ^TITLE[[:space:]]+(.*) ]]; then
            local val
            val=$(strip_cue_quotes "${BASH_REMATCH[1]}")
            if $in_track; then
                cur_title="$val"
            else
                album_title="$val"
            fi

        elif [[ "$stripped" =~ ^PERFORMER[[:space:]]+(.*) ]]; then
            local val
            val=$(strip_cue_quotes "${BASH_REMATCH[1]}")
            if $in_track; then
                cur_performer="$val"
            else
                global_performer="$val"
            fi

        elif [[ "$stripped" =~ ^INDEX[[:space:]]+01[[:space:]]+([0-9:]+) ]]; then
            cur_index="${BASH_REMATCH[1]}"

        elif [[ "$stripped" =~ ^INDEX[[:space:]]+00[[:space:]]+([0-9:]+) ]]; then
            cur_index_00="${BASH_REMATCH[1]}"
        fi
    done

    # Sauvegarder la dernière piste
    if $in_track && [[ -n "$cur_track" ]]; then
        tracks+=("$cur_track")
        titles+=("$cur_title")
        performers+=("$cur_performer")
        indices+=("$cur_index")
        indices_00+=("$cur_index_00")
    fi

    # Supprimer le slash final éventuel de destination
    destination="${destination%/}"

    # ── Répertoire cible ───────────────────────────────────────────────────────
    local target_dir="$destination/$album_title"
    if $APPLY; then
        mkdir -p "$target_dir"
        echo "Répertoire cible: '$target_dir'"
    else
        echo "[simulation] CRÉERAIT répertoire: '$target_dir'"
    fi

    # ── Image de couverture éventuelle ─────────────────────────────────────────
    local cover=""
    if [[ -f "$curdir/${album_title}.jpg" ]]; then
        cover="$curdir/${album_title}.jpg"
    fi

    # ── Génération des mp3 par piste ──────────────────────────────────────────
    local n=${#tracks[@]}
    for (( i=0; i<n; i++ )); do
        local tnum="${tracks[$i]}"
        local ttitle="${titles[$i]:-Track $tnum}"
        local tperformer="${performers[$i]:-$global_performer}"

        # Numéro sur 2 chiffres en décimal (force base 10 pour éviter octal)
        local tnum_fmt
        tnum_fmt=$(printf '%02d' "$(( 10#$tnum ))")

        # Nom du fichier : "NN PERFORMER - TITLE.mp3" ou "NN TITLE.mp3"
        # Par défaut le performer est omis (redondant avec le nom du répertoire) ;
        # --keep-performer l'inclut systématiquement.
        local mp3_name
        if [[ -n "$tperformer" ]] && $KEEP_PERFORMER; then
            mp3_name="${tnum_fmt} ${tperformer} - ${ttitle}.mp3"
        else
            mp3_name="${tnum_fmt} ${ttitle}.mp3"
        fi

        # Sanitisation : caractères interdits sur ext4 (/) et FAT32 (\ : * ? " < > |)
        # On remplace / par -, les autres par _
        mp3_name="${mp3_name//\//-}"
        mp3_name="${mp3_name//\\/\_}"
        mp3_name="${mp3_name//:/\_}"
        mp3_name="${mp3_name//\*/\_}"
        mp3_name="${mp3_name//\?/\_}"
        mp3_name="${mp3_name//</\_}"
        mp3_name="${mp3_name//>/\_}"
        mp3_name="${mp3_name//|/\_}"
        # Supprimer les caractères de contrôle éventuels (0x00-0x1f)
        mp3_name=$(printf '%s' "$mp3_name" | tr -d '\000-\037')

        local mp3_path="$target_dir/$mp3_name"

        if [[ -f "$mp3_path" ]]; then
            echo "EXISTE déjà, ignoré: '$mp3_name'"
            continue
        fi

        # Vérifier que le fichier audio source existe
        if [[ ! -f "$curdir/$audio_file" ]]; then
            echo "ERROR: fichier audio introuvable: '$curdir/$audio_file'"
            (( COUNT_ERRORS++ )) || true
            continue
        fi

        # Calcul de l'offset de début :
        # Si INDEX 00 existe pour cette piste, commencer à INDEX 00 (inclut le pre-gap
        # dans la piste courante, pour un enchaînement correct sur mix/live)
        # Sinon utiliser INDEX 01.
        local idx_start
        if [[ -n "${indices_00[$i]}" ]]; then
            idx_start="${indices_00[$i]}"
        else
            idx_start="${indices[$i]}"
        fi
        local start_sec
        start_sec=$(awk -F: '{printf "%.4f", ($1*60 + $2 + $3/75)}' <<< "$idx_start")

        local duration_arg=()
        if (( i+1 < n )); then
            # Fin = INDEX 00 de la piste suivante si présent, sinon INDEX 01
            local next_idx
            if [[ -n "${indices_00[$((i+1))]}" ]]; then
                next_idx="${indices_00[$((i+1))]}"
            else
                next_idx="${indices[$((i+1))]}"
            fi
            local end_sec
            end_sec=$(awk -F: '{printf "%.4f", ($1*60 + $2 + $3/75)}' <<< "$next_idx")
            local dur
            dur=$(awk "BEGIN {printf \"%.4f\", $end_sec - $start_sec}")
            duration_arg=(-t "$dur")
        fi

        # -ss après -i : output seek, plus lent mais fiable sur tous formats
        # -map 0:a : sélection explicite du flux audio
        local ffmpeg_args=(
            -i "$curdir/$audio_file"
            -ss "$start_sec"
            "${duration_arg[@]}"
            -map 0:a
            -q:a "$MP3_QUALITY"
            -map_metadata -1
            -metadata title="$ttitle"
            -metadata artist="$tperformer"
            -metadata album="$album_title"
        )
        [[ -n "$date_tag" ]]  && ffmpeg_args+=(-metadata year="$date_tag")
        if [[ -n "$cover" ]]; then
            ffmpeg_args=(-i "$curdir/$audio_file" -i "$cover"
                -ss "$start_sec" "${duration_arg[@]}"
                -map 0:a -map 1:v
                -c:v mjpeg -disposition:v attached_pic
                -q:a "$MP3_QUALITY"
                -map_metadata -1
                -metadata title="$ttitle"
                -metadata artist="$tperformer"
                -metadata album="$album_title"
            )
            [[ -n "$date_tag" ]] && ffmpeg_args+=(-metadata year="$date_tag")
        fi

        (( COUNT_PROCESSED++ )) || true

        if $APPLY; then
            local ffmpeg_err
            ffmpeg_err=$(mktemp)
            ffmpeg -y "${ffmpeg_args[@]}" "$mp3_path" 2>"$ffmpeg_err" &
            local ffmpeg_pid=$!
            # Permettre au trap d'interrompre ffmpeg
            trap '_cleanup; kill "$ffmpeg_pid" 2>/dev/null; wait "$ffmpeg_pid" 2>/dev/null' INT TERM
            if wait "$ffmpeg_pid"; then
                echo "CRÉÉ: '$mp3_name'"
                (( COUNT_MODIFIED++ )) || true
            else
                # Ne pas compter comme erreur si c'est une interruption
                if $_interrupted; then
                    rm -f "$ffmpeg_err" "$mp3_path"
                    return 130
                fi
                echo "ERROR: échec ffmpeg pour '$mp3_name'"
                tail -5 "$ffmpeg_err" | sed 's/^/  ffmpeg: /' >&2
                (( COUNT_ERRORS++ )) || true
            fi
            # Remettre le trap standard
            trap '_cleanup' INT TERM
            rm -f "$ffmpeg_err"
        else
            echo "[simulation] CRÉERAIT: '$mp3_name'"
            (( COUNT_MODIFIED++ )) || true
        fi
    done
}

# ─── 5b. create_mp3_sub ───────────────────────────────────────────────────────
create_mp3_sub() {
    local destination="$1"
    destination="${destination%/}"
    local curdir="$PWD"

    mapfile -t subdirs < <(find "$curdir" -maxdepth 1 -mindepth 1 -type d | sort)

    for subdir in "${subdirs[@]}"; do
        # Vérifier qu'il contient au moins un .flac ou .mp3
        local has_audio
        has_audio=$(find "$subdir" -maxdepth 1 \( -iname "*.flac" -o -iname "*.mp3" \) | head -1)
        [[ -z "$has_audio" ]] && continue

        local subname
        subname=$(basename "$subdir")

        # Conversion utf-8 du nom du sous-dossier
        local tmp_n
        tmp_n=$(mktemp)
        printf '%s' "$subname" > "$tmp_n"
        local sub_enc
        sub_enc=$(detect_encoding "$tmp_n")
        rm -f "$tmp_n"
        local subname_utf8
        subname_utf8=$(convert_string_to_utf8 "$subname" "$sub_enc")

        local target_dir="$destination/$subname_utf8"

        if $APPLY; then
            mkdir -p "$target_dir"
        else
            echo "[simulation] CRÉERAIT: '$target_dir'"
        fi

        mapfile -t files < <(find "$subdir" -maxdepth 1 -type f | sort)

        for f in "${files[@]}"; do
            local fname fbase fenc fname_utf8 target_file
            fbase=$(basename "$f")

            local tmp_fn
            tmp_fn=$(mktemp)
            printf '%s' "$fbase" > "$tmp_fn"
            fenc=$(detect_encoding "$tmp_fn")
            rm -f "$tmp_fn"

            fname_utf8=$(convert_string_to_utf8 "$fbase" "$fenc")

            (( COUNT_PROCESSED++ )) || true

            if [[ "$f" =~ \.[Ff][Ll][Aa][Cc]$ ]]; then
                # Convertir flac -> mp3
                local mp3_name="${fname_utf8%.*}.mp3"
                target_file="$target_dir/$mp3_name"
                if $APPLY; then
                    if ffmpeg -y -i "$f" -q:a 2 "$target_file" 2>/dev/null; then
                        echo "CONVERTI: '$fbase' -> '$mp3_name'"
                        (( COUNT_MODIFIED++ )) || true
                    else
                        echo "ERROR: échec conversion '$fbase'"
                        (( COUNT_ERRORS++ )) || true
                    fi
                else
                    echo "[simulation] CONVERTIRAIT: '$fbase' -> '$mp3_name' dans '$target_dir'"
                    (( COUNT_MODIFIED++ )) || true
                fi
            else
                # Copier tel quel avec nom utf-8
                target_file="$target_dir/$fname_utf8"
                if $APPLY; then
                    cp -- "$f" "$target_file"
                    echo "COPIÉ: '$fbase' -> '$target_file'"
                    (( COUNT_MODIFIED++ )) || true
                else
                    echo "[simulation] COPIERAIT: '$fbase' -> '$target_file'"
                    (( COUNT_MODIFIED++ )) || true
                fi
            fi
        done
    done
}

# ─── Parsing des arguments ────────────────────────────────────────────────────
DO_FIX_NAMES=false
DO_FIX_MD5=false
DO_CHECK_MD5=false
DO_FIX_CUE=false
DO_FIX_INDEXES=false
DO_FIX_FOLDER=false
DO_MP3=false
DO_MP3_SUB=false
MP3_DEST=""
MP3_SUB_DEST=""
KEEP_PERFORMER=false
COMPIL_PREFIX="0 Compil"
MP3_QUALITY=2
EXPLICIT_FILES=()

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix-names)   DO_FIX_NAMES=true    ; shift ;;
        --fix-md5)     DO_FIX_MD5=true      ; shift ;;
        --check-md5)   DO_CHECK_MD5=true    ; shift ;;
        --fix-cue)     DO_FIX_CUE=true      ; shift ;;
        --fix-indexes) DO_FIX_INDEXES=true  ; shift ;;
        --fix-folder)  DO_FIX_FOLDER=true   ; shift ;;
        --mp3)
            DO_MP3=true
            MP3_DEST="${2:?--mp3 requiert un répertoire destination}"
            shift 2
            ;;
        --mp3-sub)
            DO_MP3_SUB=true
            MP3_SUB_DEST="${2:?--mp3-sub requiert un répertoire destination}"
            shift 2
            ;;
        --apply)          APPLY=true           ; shift ;;
        --keep-performer) KEEP_PERFORMER=true  ; shift ;;
        --compil-prefix)
            COMPIL_PREFIX="${2:?--compil-prefix requiert une valeur}"
            shift 2
            ;;
        --mp3-quality)
            MP3_QUALITY="${2:?--mp3-quality requiert une valeur (0-9)}"
            if ! [[ "$MP3_QUALITY" =~ ^[0-9]$ ]]; then
                echo "ERROR: --mp3-quality doit être un entier entre 0 et 9" >&2
                exit 1
            fi
            shift 2
            ;;
        --help|-h)        usage ; exit 0       ;;
        *)
            # Argument non-option : traité comme un fichier explicite
            if [[ -f "$1" ]]; then
                EXPLICIT_FILES+=("$1")
                shift
            else
                echo "Option inconnue ou fichier introuvable: '$1'" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

# ─── Sélection des fichiers ───────────────────────────────────────────────────
# Retourne la liste des fichiers à traiter pour une extension donnée.
# Si des fichiers explicites ont été passés en argument, filtre sur l'extension.
# Sinon, cherche tous les fichiers de ce type dans le répertoire courant.
get_files() {
    local ext="$1"   # ex: "cue", "md5"
    if (( ${#EXPLICIT_FILES[@]} > 0 )); then
        for f in "${EXPLICIT_FILES[@]}"; do
            [[ "$f" == *."$ext" ]] && echo "$f"
        done
    else
        find "$PWD" -maxdepth 1 -name "*.$ext" | sort
    fi
}

# ─── Exécution ────────────────────────────────────────────────────────────────
GLOBAL_RC=0

if ! $APPLY; then
    echo "=== MODE SIMULATION (ajouter --apply pour appliquer) ==="
fi

# 1. fix-names
if $DO_FIX_NAMES; then
    echo "--- fix-names ---"
    _rc=0; fix_names || _rc=$?
    register_file_rc "(répertoire courant)" $_rc
    (( GLOBAL_RC |= _rc )) || true
fi

# 2. fix-md5 / check-md5
if $DO_FIX_MD5 || $DO_CHECK_MD5; then
    $DO_FIX_MD5 && echo "--- fix-md5 ---"
    $DO_CHECK_MD5 && ! $DO_FIX_MD5 && echo "--- check-md5 ---"
    mapfile -t md5files < <(get_files md5)
    for md5f in "${md5files[@]}"; do
        base=$(basename "$md5f")
        new_base=$(compute_new_name "$PWD" "$base")
        new_path="$(dirname "$md5f")/$new_base"
        $DO_CHECK_MD5 && echo "Fichier: '$base'"
        _rc=0; fix_md5 "$md5f" "$new_path" "$DO_CHECK_MD5" || _rc=$?
        register_file_rc "$base" $_rc
        (( GLOBAL_RC |= _rc )) || true
    done
fi

# 3. fix-cue / fix-indexes
if $DO_FIX_CUE || $DO_FIX_INDEXES; then
    $DO_FIX_CUE && $DO_FIX_INDEXES && echo "--- fix-cue + fix-indexes ---"
    $DO_FIX_CUE && ! $DO_FIX_INDEXES && echo "--- fix-cue ---"
    ! $DO_FIX_CUE && $DO_FIX_INDEXES && echo "--- fix-indexes ---"
    mapfile -t cuefiles < <(get_files cue)
    for cuef in "${cuefiles[@]}"; do
        base=$(basename "$cuef")
        new_base=$(compute_new_name "$PWD" "$base")
        new_path="$(dirname "$cuef")/$new_base"
        _rc=0; fix_cue "$cuef" "$new_path" || _rc=$?
        register_file_rc "$base" $_rc
        (( GLOBAL_RC |= _rc )) || true
    done
fi

# 4. fix-folder
if $DO_FIX_FOLDER; then
    echo "--- fix-folder ---"
    fix_folder || true
fi

# 5a. mp3
if $DO_MP3; then
    echo "--- mp3 -> '$MP3_DEST' ---"
    mapfile -t cuefiles < <(get_files cue)
    for cuef in "${cuefiles[@]}"; do
        create_mp3 "$cuef" "$MP3_DEST" || true
    done
fi

# 5b. mp3-sub
if $DO_MP3_SUB; then
    echo "--- mp3-sub -> '$MP3_SUB_DEST' ---"
    create_mp3_sub "$MP3_SUB_DEST" || true
fi

# ─── Bilan ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Bilan ==="
echo "  Traités       : $COUNT_PROCESSED"
echo "  Modifiés      : $COUNT_MODIFIED"
echo "  Avertissements: $COUNT_WARNINGS"
echo "  Erreurs       : $COUNT_ERRORS"
if (( ${#FILES_WITH_ERRORS[@]} > 0 )); then
    echo "  Fichiers en erreur:"
    for f in "${FILES_WITH_ERRORS[@]}"; do echo "    $f"; done
fi
if (( ${#FILES_WITH_WARNINGS[@]} > 0 )); then
    echo "  Fichiers avec avertissements:"
    for f in "${FILES_WITH_WARNINGS[@]}"; do echo "    $f"; done
fi

FINAL_RC=$GLOBAL_RC
(( COUNT_MODIFIED  > 0 )) && (( FINAL_RC |= RC_MODIFIED  )) || true
(( COUNT_ERRORS    > 0 )) && (( FINAL_RC |= RC_ERROR     )) || true
(( COUNT_WARNINGS  > 0 )) && (( FINAL_RC |= RC_WARNING   )) || true
# Bit erreur exclut bit modification (valeurs 3 et 7 impossibles)
(( FINAL_RC & RC_ERROR )) && (( FINAL_RC &= ~RC_MODIFIED )) || true
exit $FINAL_RC
