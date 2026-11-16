# Scénario de test joué sur les machines Windows de GitHub : lance Flocon.exe, le pilote, vérifie son état
# et prend une capture d'écran à chaque étape. Usage : powershell -File windows/tests/test.ps1 chemin\Flocon.exe
param([string]$exe)
$ErrorActionPreference = "Stop"
# une erreur arrête tout de suite le script, fenêtres de test comprises (sinon elles le gardent en vie)
trap { Write-Host $_; Write-Host $_.ScriptStackTrace; [Environment]::Exit(1) }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(IntPtr c, string t);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[W.U]::SetProcessDPIAware() | Out-Null
New-Item -ItemType Directory -Force shots | Out-Null
$ordre = Join-Path $env:TEMP "flocon-ordre.txt"
$etatF = Join-Path $env:TEMP "flocon-etat.txt"

function Vivant($quoi) { if (-not (Get-Process Flocon -ErrorAction SilentlyContinue)) { throw "Flocon s'est arrêté ($quoi)" } }
function Photo($nom) {
    $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $bmp.Save("shots\$nom.png"); $g.Dispose(); $bmp.Dispose()
    Vivant $nom
}
function Ordre($quoi) { Set-Content -Path $ordre -Value $quoi -NoNewline; Start-Sleep -Milliseconds 700 }
# L'état que Flocon déclare : un dictionnaire (etat, flocons, rebords, neige_sol, neige_fenetres, fond_ok…)
function Etat($nom) {
    Remove-Item $etatF -ErrorAction SilentlyContinue
    Ordre "etat"
    $ligne = Get-Content $etatF
    Write-Host "[$nom] $ligne"
    Add-Content etats.txt "[$nom] $ligne"
    $d = @{}
    foreach ($p in $ligne -split " ") { $kv = $p -split "="; $d[$kv[0]] = $kv[1] }
    return $d
}
function Verifie($ok, $quoi) { if (-not $ok) { throw "ÉCHEC : $quoi" } else { Write-Host "ok : $quoi" } }
# Fenêtre de test ordinaire, tenue par un autre fil de ce script, que le test déplace ensuite de l'extérieur
function Fenetre($titre, $x, $y, $w, $h) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ param($t, $x, $y, $w, $h)
        Add-Type -AssemblyName System.Windows.Forms
        $f = New-Object Windows.Forms.Form
        $f.Text = $t; $f.StartPosition = 'Manual'; $f.SetBounds($x, $y, $w, $h)
        [Windows.Forms.Application]::Run($f)
    }).AddArgument($titre).AddArgument($x).AddArgument($y).AddArgument($w).AddArgument($h)
    [void]$ps.BeginInvoke()
    Start-Sleep 4
    $hwnd = [W.U]::FindWindow([IntPtr]::Zero, $titre)
    Verifie ($hwnd -ne [IntPtr]::Zero) "la fenêtre « $titre » est ouverte"
    [W.U]::ShowWindow($hwnd, 1) | Out-Null   # au cas où la machine de test lance tout en caché
}
function Bouge($titre, $x, $y, $w, $h) { [W.U]::MoveWindow([W.U]::FindWindow([IntPtr]::Zero, $titre), $x, $y, $w, $h, $true) | Out-Null }

# 1. tests internes et diagnostic
$p = Start-Process $exe -ArgumentList "--selftest" -Wait -PassThru
Verifie ($p.ExitCode -eq 0) "tests internes"
Start-Process $exe -ArgumentList "--diag", "$PWD\diag.txt" -Wait
Get-Content diag.txt

# 2. premier lancement : message de bienvenue
Remove-Item HKCU:\Software\Flocon -Recurse -ErrorAction SilentlyContinue
Start-Process $exe
Start-Sleep 8
Photo "1-accueil"
Stop-Process -Name Flocon -Force
Start-Sleep 2

# 3. lancement normal, cadence au maximum, avec une fenêtre ouverte
New-Item HKCU:\Software\Flocon -Force | Out-Null
Set-ItemProperty HKCU:\Software\Flocon accueilli 1 -Type DWord
Set-ItemProperty HKCU:\Software\Flocon cadence 100 -Type DWord
Fenetre "Fenetre de test" 200 150 500 350
Start-Process $exe -ArgumentList "--pilote"
Start-Sleep 5
$e = Etat "depart"
Verifie ($e.etat -eq "0") "il neige"
Verifie ([int]$e.flocons -gt 100) "des flocons tombent ($($e.flocons))"
Verifie ($e.fond_ok -eq "1") "le calque des flocons est juste au-dessus du bureau"
Verifie ([int]$e.rebords -ge 1) "la fenêtre de test est reconnue"
Start-Sleep 45
Photo "2-neige-50s"
$e = Etat "50s"
Verifie ([int]$e.neige_fenetres -gt 0) "la neige se pose sur la fenêtre"
Verifie ([int]$e.neige_sol -gt 0) "la neige se pose en bas de l'écran"
$avant = [int]$e.neige_fenetres

# 4. fenêtre déplacée (la neige suit), puis rétrécie (ce qui dépasse tombe)
Bouge "Fenetre de test" 100 250 500 350
Start-Sleep 1
Photo "3-fenetre-deplacee"
$e = Etat "deplacee"
Verifie ([int]$e.neige_fenetres -ge $avant) "la neige est restée sur la fenêtre déplacée"
$avant = [int]$e.neige_fenetres
Bouge "Fenetre de test" 100 250 300 350
Start-Sleep -Milliseconds 300
Photo "4-fenetre-retrecie"
Start-Sleep 1
$e = Etat "retrecie"
Verifie ([int]$e.neige_fenetres -lt $avant) "la neige qui dépassait est tombée"

# 5. nouvelle fenêtre (sans neige au départ), puis la première fermée
Fenetre "Deuxieme fenetre" 620 300 300 250
Photo "5-nouvelle-fenetre"
$e = Etat "nouvelle"
Verifie ([int]$e.rebords -ge 2) "la deuxième fenêtre est reconnue"
[W.U]::PostMessage([W.U]::FindWindow([IntPtr]::Zero, "Fenetre de test"), 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep 2
Photo "6-fenetre-fermee"
$e2 = Etat "fermee"
Verifie ([int]$e2.rebords -lt [int]$e.rebords) "la fenêtre fermée n'a plus de neige"

# 6. fenêtre réduite dans la barre des tâches, puis restaurée
[W.U]::ShowWindow([W.U]::FindWindow([IntPtr]::Zero, "Deuxieme fenetre"), 6) | Out-Null
Start-Sleep 2
$e3 = Etat "reduite"
Verifie ([int]$e3.rebords -lt [int]$e2.rebords) "la fenêtre réduite n'a plus de neige"
[W.U]::ShowWindow([W.U]::FindWindow([IntPtr]::Zero, "Deuxieme fenetre"), 9) | Out-Null
Start-Sleep 2

# 7. verrouillage puis déverrouillage
Ordre "verrou"
Start-Sleep 2
Photo "7-verrouille"
Verifie ((Etat "verrou").etat -eq "2") "verrouillé : tout est arrêté"
Ordre "deverrou"
Start-Sleep 12
Photo "8-deverrouille"
Verifie ((Etat "deverrou").etat -eq "0") "déverrouillé : il neige de nouveau"

# 8. désactivation puis réactivation
Ordre "off"
Start-Sleep 2
Photo "9-desactive"
Verifie ((Etat "off").etat -eq "2") "désactivé : tout est arrêté"
Ordre "on"
Start-Sleep 12
Photo "10-reactive"
$e = Etat "on"
Verifie ($e.etat -eq "0" -and [int]$e.flocons -gt 100) "réactivé : il neige de nouveau"

# 9. maltraitance : ordres et déplacements en rafale
foreach ($i in 1..8) {
    Ordre "off"; Ordre "on"; Ordre "verrou"; Ordre "deverrou"
    Bouge "Deuxieme fenetre" (100 + $i * 30) 200 (250 + $i * 40) 300
}
Start-Sleep 5
Photo "11-apres-rafale"
Verifie ((Etat "rafale").etat -eq "0") "encore en vie après la rafale"

# 10. consommation, puis quitter proprement et relancer
$proc = Get-Process Flocon
$cpu1 = $proc.TotalProcessorTime.TotalSeconds; Start-Sleep 10; $proc.Refresh()
$pct = [math]::Round(($proc.TotalProcessorTime.TotalSeconds - $cpu1) * 10 / [Environment]::ProcessorCount, 1)
"processeur : $pct % (sur $([Environment]::ProcessorCount) coeurs), mémoire : $([math]::Round($proc.WorkingSet64 / 1MB)) Mo" | Tee-Object cpu.txt
Ordre "quitter"
Start-Sleep 3
Verifie (-not (Get-Process Flocon -ErrorAction SilentlyContinue)) "Flocon se quitte proprement"
Start-Process $exe -ArgumentList "--pilote"
Start-Sleep 15
Photo "12-relance"
Verifie ((Etat "relance").etat -eq "0") "relancé : il neige"
Stop-Process -Name Flocon -Force
Write-Host "TOUT EST BON"
[Environment]::Exit(0)
