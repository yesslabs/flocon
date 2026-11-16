# Flocon : mémo pour les prochaines conversations

Flocon fait tomber de la neige sur le bureau de l'ordinateur. La neige se pose sur les fenêtres et en bas de l'écran, et on joue avec. Il existe une version Mac et une version Windows. Les deux sont vendues ensemble en un seul produit Gumroad à 4,99 € hors TVA, sans compte développeur Apple ni certificat Windows.

Ce fichier résume tout ce qui a été construit, décidé et appris. Le guide du dossier pour l'utilisateur est [LISEZ-MOI.md](LISEZ-MOI.md).

## Comment travailler avec l'utilisateur

- **Toujours répondre en français**, avec des mots simples : il n'est pas développeur. Le résultat d'abord, puis les détails utiles.
- Dans VSCode, citer les fichiers en liens markdown relatifs, par exemple [mac/main.swift](mac/main.swift).
- **Après chaque amélioration de l'app Mac** : `mac/build.sh`, puis `pkill -x Flocon`, puis `open mac/Flocon.app`, sans demander. **Pour toute autre app ou démo visible, demander avant de lancer quoi que ce soit.** Il l'a demandé explicitement.
- **Aucune information personnelle dans ce qui est livré ou publié** : ni prénom, ni nom, ni e-mail perso, ni chemin `/Users/…`. Les zips ont été fouillés pour ça. Le seul contact public est `flocon.app@gmail.com`.
- **Ne rien produire qu'il n'a pas demandé.** Il a refusé une image de couverture Gumroad fabriquée sans son accord. Proposer d'abord, puis faire.
- Avant une action visible de l'extérieur (publication, envoi, suppression), demander. Les clics de mise en vente sur Gumroad (Publish, Unpublish) lui reviennent.
- Toujours dire honnêtement ce qui a été vérifié et ce qui ne l'a pas été.

## Le dossier

| Chemin | Rôle |
|---|---|
| [mac/main.swift](mac/main.swift) | Toute l'app Mac (Swift, AppKit + SpriteKit + SwiftUI), environ 2 100 lignes |
| [mac/build.sh](mac/build.sh) | Compile `mac/Flocon.app`, universelle (puce Apple + Intel), macOS 15 minimum, signature ad hoc, puis lance `--selftest` |
| [mac/package.sh](mac/package.sh) | Lance build.sh puis crée `dist/Flocon-Mac-1.0.zip` avec `ditto`, qui garde la signature intacte (ne pas utiliser `zip`) |
| [mac/LISEZ-MOI.txt](mac/LISEZ-MOI.txt) | Notice de l'acheteur Mac, glissée dans le zip |
| `mac/tests/` | Outils du test GitHub Mac : `ordre.sh`, `outils.sh`, `souris.swift`, `fenetre.swift` |
| [windows/Flocon.cs](windows/Flocon.cs) | Toute l'app Windows (C#, .NET Framework 4.8, WinForms + dessin à la main), environ 1 400 lignes |
| [windows/Flocon.csproj](windows/Flocon.csproj) | Projet de compilation. On ne peut **pas** compiler sur le Mac : seulement via GitHub |
| [windows/LISEZ-MOI.txt](windows/LISEZ-MOI.txt) | Notice de l'acheteur Windows |
| [windows/tests/test.ps1](windows/tests/test.ps1) | Scénario de test Windows. Doit rester en **UTF-8 avec BOM**, sinon PowerShell 5 casse les accents |
| [gumroad/landing.html](gumroad/landing.html) | La page de vente sur mesure publiée sur Gumroad |
| `dist/` | **Les deux zips à vendre**, versionnés dans git |
| `captures-test/` | Captures des derniers tests (ignorées par git) |
| `.github/workflows/` | `test-mac.yml` et `test-windows.yml`, lancés à la main |

Dépôt GitHub privé : https://github.com/yesslabs/flocon (branche `main`, `gh` connecté en `yesslabs`).

## Fonctions (identiques sur Mac et Windows)

- Flocons derrière les fenêtres, portés par le vent ; cadence réglable.
- Neige qui se pose sur le haut des fenêtres et en bas de l'écran : le Dock sur Mac, la barre des tâches sur Windows.
- Fenêtre déplacée : la neige suit. Rétrécie, fermée ou réduite : la neige tombe. Secouée : la neige est projetée.
- Le curseur balaie la neige et la projette s'il va vite.
- Clic maintenu dans la neige : une boule naît. On la roule pour la grossir, puis on la lâche ou on la lance. Trop petite, elle fond ; lancée, elle s'écrase. Trois boules empilées font un bonhomme.
- Chasse-neige, lancé depuis le menu : il dégage le sol et renverse ce qui traîne.
- Pause au verrouillage ; évaporation quand on désactive.
- Icône dans la barre des menus (Mac) ou près de l'horloge (Windows) : activer, cadence, chasse-neige, ouvrir au démarrage, présentation, quitter.
- Fenêtre de présentation au premier lancement seulement.

Limites connues : écran principal seulement sur les deux systèmes. Sur Windows, la neige ne glisse pas sur une fenêtre déplacée doucement.

## Détails techniques à connaître

### Mac
- Identifiant de l'app : **`app.flocon.mac`**. Ne plus jamais le changer : les réglages des acheteurs (préférences `accueilli`, `cadence`, `mode`) sont rangés dessous. L'ancien identifiant contenait le prénom de l'utilisateur et a été retiré avant la première vente.
- Utilise des fonctions privées de macOS (chargées dynamiquement) pour lire la position des fenêtres et du Dock. C'est la raison du minimum **macOS 15** : rien n'a été testé avant (13 et 14 non disponibles sur GitHub), et ces fonctions changent d'une version à l'autre.
- Options : `--selftest` (tests internes), `--diag` (ce que la machine offre), `--pilote` (obéit aux notifications `app.flocon.mac.pilote` avec `chasse`, `off`, `on` ; sert au test GitHub).
- Pour revoir la présentation sur le Mac de l'utilisateur : `defaults delete app.flocon.mac` (efface aussi ses réglages).

### Windows
- Deux calques plein écran transparents, que les clics traversent : « fond », juste au-dessus du bureau (flocons), et « avant », toujours au premier plan (neige posée, boules, chasse-neige). Le calque avant capte les clics seulement dans la neige ou sur une boule, avec un voile presque invisible autour du curseur : sans lui, Windows laissait passer le clic là où le curseur venait de creuser.
- Fenêtres lues à chaque image (`EnumWindows` + DWM). Réglages dans `HKCU\Software\Flocon`, démarrage automatique par la clé `Run`.
- Options : `--selftest`, `--diag fichier`, `--pilote` (lit les ordres dans `%TEMP%\flocon-ordre.txt` : `off`, `on`, `verrou`, `deverrou`, `etat`, `chasse`, `neige`, `quitter` ; écrit l'état dans `%TEMP%\flocon-etat.txt`).
- Exe d'environ 140 Ko, sans rien à installer : .NET Framework 4.8 est déjà dans Windows 10 et 11.

## Tester

Sur https://github.com/yesslabs/flocon/actions, lancer « Test Flocon Mac » ou « Test Flocon Windows », ou en ligne de commande :

```
gh workflow run "Test Flocon Mac"
gh workflow run "Test Flocon Windows"
```

- **Mac** : 4 machines (macOS 15 et 26, puce Apple et Intel), scénario complet avec 16 captures, échec en cas de plantage.
- **Windows** : Windows Server 2022 (base Windows 10) et 2025 (base Windows 11). Le scénario pilote la vraie souris (balayage, trois boules, bonhomme, chasse-neige), vérifie l'état à chaque étape et produit environ 20 captures. Il fabrique aussi l'artifact **`zip-a-vendre`**.
- Les machines GitHub n'ont pas de carte graphique (environ 25 images par seconde) : la fluidité réelle ne se juge que sur un vrai ordinateur.

Pièges déjà rencontrés dans les tests :
- Mac : TextEdit bloque les AppleEvents sur GitHub, d'où une fenêtre de test maison (`fenetre.swift`). Le menu se trouve via `menu bar 1`. Les étapes ont un délai maximal de 45 secondes.
- Windows : passer `[IntPtr]::Zero` (pas `$null`) à `FindWindow`. La console de GitHub passe devant les fenêtres de test, qu'il faut remettre au premier plan. Le compteur `neige_fenetres` additionne **toutes** les fenêtres, console comprise : comparer des écarts, pas des proportions.

## Sortir une nouvelle version

1. Changer le numéro à **trois endroits** : `VERSION=` dans [mac/build.sh](mac/build.sh), `<Version>` dans [windows/Flocon.csproj](windows/Flocon.csproj), `Version = ` dans [windows/Flocon.cs](windows/Flocon.cs). Le nom des zips et du dossier `Flocon 1.0` dans le workflow Windows suit aussi le numéro.
2. Mac : `mac/package.sh`, puis relancer l'app, puis le test GitHub Mac.
3. Windows : `git push`, lancer « Test Flocon Windows », récupérer l'artifact `zip-a-vendre` et le mettre dans `dist/`.
4. Vérifier que les zips ne contiennent aucune info personnelle (chercher le prénom, le nom, `gmail`, `/Users/`).
5. Sur Gumroad, onglet Content : remplacer les deux fichiers. Les anciens acheteurs récupèrent la nouvelle version par leur lien. Les nouvelles versions sont aussi annoncées aux acheteurs par e-mail (promis dans les notices).

Si seule une notice change, on peut remplacer le `LISEZ-MOI.txt` dans le zip Windows sans recompiler.

## Gumroad

- Compte vendeur « Flocon », contact `flocon.app@gmail.com` (adresse dédiée, créée pour ne pas exposer l'adresse perso).
- **Page à partager : https://flocon.gumroad.com/l/flocon.** `flocon.gumroad.com` tout court est la vitrine de Gumroad (une carte produit blanche) : on ne peut pas la personnaliser, sauf couleurs et police via « Edit profile ».
- Identifiant du produit pour l'outil en ligne de commande : **`0u5Q8KS9Y1hGPjHOqf-KOw==`**. Le nom court `flocon` est refusé (« product not found »).
- Produit **en vente depuis le 16 novembre 2026**. Contenu : un dossier « Flocon 1.0 » avec les deux zips. Pas d'image de couverture (choix de l'utilisateur), miniature = icône de l'app.
- Prix 4,99 € **hors TVA** : un client français paie 5,99 €. Gumroad ajoute la TVA selon le pays et la reverse lui-même. Le pourboire est activé par défaut sur la page de paiement, qu'on ne peut pas personnaliser.
- Achat test : connecté en vendeur, la page de paiement affiche « This will be a test purchase » et ne débite rien. En navigation privée, c'est un vrai paiement.
- L'acheteur n'a pas besoin de compte Gumroad.

### Page de vente sur mesure ([gumroad/landing.html](gumroad/landing.html))
Toute la page est enneigée : la neige se pose sur le bouton d'achat, les cartes et le bloc final, et le curseur la balaie. Un bureau simulé montre des fenêtres qu'on attrape et qu'on secoue. Elle gère le mode clair, le mode sombre et le téléphone, et suit les coins arrondis.

Outil installé avec Homebrew (`brew tap antiwork/cli`, `brew install antiwork/cli/gumroad`), connecté au compte Flocon par l'utilisateur via `gumroad auth login`.

```
ID='0u5Q8KS9Y1hGPjHOqf-KOw=='
gumroad products page preview "$ID" ./gumroad/landing.html --json --no-input --non-interactive   # contrôle sans publier
gumroad products page publish "$ID" ./gumroad/landing.html --json --no-input --non-interactive   # met en ligne
gumroad products page clear   "$ID" --yes --json --no-input --non-interactive                    # revient à la page par défaut
```

- Toujours lancer `preview` d'abord et lire `.sanitization_report`. Le filtre retire sans conséquence `meta` et `title`. Il retire aussi la balise SVG `<use>` : dessiner chaque forme en entier.
- La page doit garder au moins un élément `data-gumroad-action="buy"`, sinon le produit n'est plus achetable. Le prix s'affiche avec `data-gumroad-field="price"`.
- Pour la contrôler sans navigateur visible : `~/Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell --headless --screenshot=… --window-size=…`.
- Cette page ne se publie que depuis Claude Code sur ce Mac, où se trouvent l'outil et la connexion.

## Ce que l'acheteur rencontre à l'installation

- **Mac** : « Élément « Flocon » non ouvert ». Il faut cliquer sur **Terminé** (surtout pas « Placer dans la corbeille »), puis Réglages Système → Confidentialité et sécurité → **Ouvrir quand même**. Supprimer cette étape demanderait un compte développeur Apple (99 $ par an) pour signer et notariser l'app.
- **Windows** : SmartScreen (« Informations complémentaires » → « Exécuter quand même »). Sur certains PC Windows 11, le **Contrôle intelligent des applications** bloque sans échappatoire : il faut le désactiver, ce qui est définitif. Ce blocage est arrivé sur un PC de test, mais un autre PC Windows 11 a lancé l'app sans problème : cela dépend du réglage de chaque PC. Le supprimer demanderait un certificat de signature ou le Microsoft Store.
- Ces deux points figurent dans les notices et sur la page de vente.

## Historique

- **10 novembre 2026** : l'utilisateur demande de ne plus ouvrir l'app sans son accord.
- **15 novembre** : l'app Mac, appelée d'abord « Neige », est renommée **Flocon**. Premier zip à vendre, premiers tests sur les Mac de GitHub. Il demande de relancer l'app automatiquement après chaque amélioration.
- **16 novembre** :
  - Scénario de test Mac élargi (fenêtres, boule, chasse-neige, verrouillage, menu, rafale, relance).
  - Dossier réorganisé en `mac/`, `windows/`, `dist/`.
  - Première version Windows (neige seulement), testée par l'utilisateur sur un vrai PC.
  - Version Windows complète, avec toutes les fonctions du Mac et la fenêtre de présentation, validée sur GitHub puis sur un vrai PC Windows 11.
  - Notices complétées : blocage Windows 11, mises à jour, contact.
  - Identifiant Mac neutralisé (`app.flocon.mac`) ; minimum passé à macOS 15.
  - Gumroad : produit créé, page de vente sur mesure, mise en vente, premier achat test (téléchargement Mac validé, avertissement Gatekeeper attendu).

## Pistes ouvertes

- Le **message de remerciement du reçu** est vide sur Gumroad (le texte proposé n'a jamais été enregistré).
- Vérifier sur un vrai iPhone la page de vente. Au doigt, le balayage de la neige est limité car le doigt fait défiler la page.
- Vérifier sur le reçu et la facture de l'achat test qu'aucun nom personnel n'apparaît.
- Éventuellement : couleurs de la vitrine Gumroad (Edit profile), désactiver le pourboire, signer les apps (Apple et Windows) pour supprimer les blocages, multi-écran.
- Pour régénérer l'icône en PNG : `sips -s format png mac/AppIcon.icns --out icone-Flocon.png` (1024 × 1024, fond transparent).
