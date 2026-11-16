# Flocon — il neige sur le bureau

Deux versions de la même app, chacune dans son dossier. Elles ne partagent aucun code.

| Dossier | Ce qu'il contient |
|---|---|
| `mac/` | La version Mac. `main.swift` est toute l'app. `./build.sh` la compile, `./package.sh` refait le zip à vendre. |
| `windows/` | La version Windows. `Flocon.cs` est toute l'app. Elle se compile sur GitHub (voir plus bas), pas sur le Mac. |
| `dist/` | **Les zips à vendre** : `Flocon-Mac-1.0.zip` et `Flocon-Windows-1.0.zip`. |
| `captures-test/` | Les captures d'écran des derniers tests (non envoyées sur GitHub). |
| `.github/workflows/` | Les tests automatiques sur les machines de GitHub. |

Dans chaque dossier, `LISEZ-MOI.txt` est la notice glissée dans le zip pour l'acheteur, et `tests/` contient le scénario de test.

## Lancer les tests

Sur https://github.com/yesslabs/flocon/actions, choisir « Test Flocon Mac » ou « Test Flocon Windows », puis « Run workflow ».
Les captures d'écran sont dans « Artifacts », en bas de la page du test.

## Refaire le zip Windows après une modification

1. Envoyer la modification sur GitHub (`git push`).
2. Lancer « Test Flocon Windows ».
3. Télécharger l'artifact « zip-a-vendre » et mettre son `Flocon-Windows-1.0.zip` dans `dist/`.

## Différences entre Windows et Mac

La version Windows a les mêmes fonctions que la version Mac. Deux limites : la neige tombe sur l'écran principal seulement, et elle ne glisse pas sur une fenêtre qu'on déplace doucement (elle tombe quand on la secoue).

## Blocage sur certains PC Windows 11

Flocon.exe n'est pas signé. Sur les PC où le « Contrôle intelligent des applications » est activé (installations récentes de Windows 11), Windows le bloque sans bouton pour passer outre. L'acheteur doit désactiver cette protection (étapes dans `windows/LISEZ-MOI.txt`), ce qui est définitif. Pour supprimer ce blocage : signer l'app avec un certificat reconnu, ou la publier sur le Microsoft Store.
