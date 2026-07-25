# Outils de gestion de la cdthèque

# Objectif
Le but principal est de renommer les fichiers et les pistes de façon cohérente.
Optionnellement, le script peut vérifier les md5 et générer des mp3 vers un emplacement spécifié.

# Structure de la cdthèque
La cdthèque ciblée est construite comme suit:
Un répertoire par artiste, sauf pour les compilations qui sont dans des répertoires de la forme "0 Compil genre".
Le préfixe des compilations est paramétrable.
Habituellement 4 fichiers par album, avec le même nom de base:
- un fichier .cue
- un fichier .flac (un seul fichier par album)
- un fichier .flac.md5
- un fichier .jpg
- parfois d'autres fichiers, par exemple .log
Et parfois des sous-répertoires contenant pour un album des fichiers .flac ou .mp3 (un fichier par piste)

Exemples de noms de fichier:
0 Compil - BO/Various Artists - Jazz & Cinéma.cue
0 Compil - BO/Various - Mémoires d'immigrés, l'Héritage maghrébin.md5
0 Compil - world/VA - Bush Taxi Mali - Field Recordings From Mali.flac
48 Cameras/48 Cameras and Gerard Malanga - Three Weeks With My Dog.cue
48 Cameras/48 Cameras -  Me, My Youth & A Bass Drum.flac
AC-DC/AC-DC - For Those About To Rock DSC_6857.JPG

Règles de renommage et de conversion:
si le répertoire commence par la chaîne "0 Compil" ou celle spécifiée par le paramètre --compil-prefix :
  Supprimer Various Artists, Various artists, Various, VA, Artistes divers, le tiret et les deux espaces qui l'entourent en début de nom
Sinon, sauf si --keep-performer est spécifié:
  Supprimer le début du nom, le tiret et les deux espaces si la partie avant espace tiret espace correspond exactement au nom du répertoire
Dans tous les cas:
Convertir les noms en utf-8 si nécessaire, le nom de départ est parfois en cp-1252, parfois déjà en utf-8

Résultat attendu pour les exemples si --keep-performer n'est pas spécifié:
0 Compil - BO/Jazz & Cinéma.cue
0 Compil - BO/Mémoires d'immigrés, l'Héritage maghrébin.md5
0 Compil - world/Bush Taxi Mali - Field Recordings From Mali.flac
48 Cameras/48 Cameras and Gerard Malanga - Three Weeks With My Dog.cue
48 Cameras/Me, My Youth & A Bass Drum.flac
AC-DC/For Those About To Rock DSC_6857.JPG

#Utilisation

## Script principal:
cdtheque.sh
Lancez-le sans argument pour voir les options disponibles.
Le script travaille par défaut sur tout le répertoire courant, mais il est aussi possible de spécifier des fichiers particuliers.

Conseil:
Lancez-le une première fois sans l'option --apply pour voir ce qu'il ferait
Si le résultat est correct, lancez le avec l'option --apply pour appliquer les modifications

Des détails sont donnés plus bas.

## Outil annexe
fix_cue_swap.sh
Options: --use-separator SEP, --performer-last
Dans ma cdthèque il y a des cue erronés.
Ce script corrige deux sortes d'erreurs:
- TITLE et PERFORMER sont intervertis
- TITLE commence par ce qui devrait être PERFORMER suivi d'un séparateur, ou le contraire
Attention! Seul le séparateur exact sera traité, incluez les éventuels espaces.
Exemple: --use-separator " - "

# 1) Travail sur les noms de fichiers et de répertoires
options: --fix-names, --keep-performer
fonction: fix_names()
appliquer les règles de renommage et de conversion à tous les fichiers et sous-répertoires de premier niveau du répertoire courant
signaler les éventuels conflits avec des fichiers pré-existants

# 2) Travail sur le contenu de tous les fichiers .md5
options: --fix-md5, --keep-performer
fonction: fix_md5 (md5file, new_filename)

Appliquer les mêmes règles de renommage et de conversion
Remplacer l'éventuelle astérisque avant le nom de fichier par un espace
Vérifier que le ou les fichier(s) référencé(s) existe(nt)

Ajouter 5 minutes au timestamp d'origine s'il y a eu modification du contenu (ne pas utiliser le temps actuel)

# 3) Travail sur le contenu de tous les fichiers .cue
options: --fix-cue, --keep-performer, --fix-indexes
fonction: fix_cue (cuefile, new_filename)

Appliquer les mêmes règles de renommage et de conversion au champ FILE
Vérifier que le fichier référencé par FILE existe
Appliquer la conversion UTF-8 à tous les champs texte, et notamment à TITLE (celui de l'albume et ceux des pistes) et à PERFORMER
Avec --fix-indexes: si une piste n'a pas d'index 01 mais qu'elle a un index 00, transformer le 00 en 01

Ajouter 5 minutes au timestamp d'origine s'il y a eu modification du contenu (ne pas utiliser le temps actuel)

# 4) Travail sur les timestamp des répertoires
Appliquer au répertoire parent le timestamp du fichier le plus récent qu'il contient
option: --fix-folder
fonction: fix_folder ()
s'applique au répertoire courant

# 5) Conversion en mp3
options: --mp3 destination où destination est le répertoire cible parent, --mp3-quality N, --keep-performer
fonction: create_mp3(cuefile, destination)

- crée le repertoire cible dans la destination et le sous répertoire titre de l'album extrait du cue
  précédé du numéro de piste sur deux chiffres
  ainsi que du performer suivi de " - " si --keep-performer est spécifié
- crée un fichier par piste avec le nom figurant dans le champ TITLE du .cue, en remplaçant les caractères incompatibles avec ext4 et fat32
- ajoute les tags année à partir de REM DATE si présent dans le cue, PERFORMER, TITLE de l'album
- s'il existe un fichier de la forme TITLE de l'album.jpg, il sera inclus dans les mp3

fonction: create_mp3-sub(destination)
s'il y a des sous-dossiers au répertoire courant
copier l'entièreté du sous-dossier vers destination en convertissant les éventuels fichiers .flac en .mp3
et en convertissant les noms de fichiers et du sous-dossier en utf-8 si nécessaire
(aucune analyse d'éventuels fichiers cue ou md5)

Aucun fichier du répertoire courant ou de ses éventuels sous-répertoires n'est modifié par ces fonctions

# 6) Remarques additionnelles
- les noms de fichiers peuvent comporte des caractères spéciaux tels ' " [ ] ( ) ; ? $ & mais pas de saut de ligne
- si le codage n'est pas reconnu (ni ASCII, ni CP-1252, ni UTF-8), un message d'erreur sera émis
- par défaut les modifications ne sont pas appliquées mais des messages indiquant ce qui serait modifié sont émis;
  pour appliquer, --apply doit être donné explicitement en argument
- après les traitements, un décompte des fichiers traités, modifiés ou erronés est émis
  pour cela, les fonctions renvoient 0 s'il n'y a pas eu de modification, 1 pour une modification réussie, 2 si erreur
  valeur à laquelle on ajoute 4 en cas d'avertissement
- le script s'applique toujours au répertoire courant
  sans exploration des sous-répertoires à l'exception d'un niveau pour l'option --mp3
  si vous souhaitez l'appliquer à plusieurs répertoire d'un coup, utilisez find avec l'option execdir
