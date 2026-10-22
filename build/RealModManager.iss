; R.E.A.L. Mod Manager - Inno Setup Skript (Inno Setup 6)
; Wird von build\Build-Release.ps1 aufgerufen: ISCC.exe /DAppVersion=x.y.z /DStageDir=... /DOutDir=... RealModManager.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #define StageDir "..\dist\stage-installer\R.E.A.L. Mod Manager"
#endif
#ifndef OutDir
  #define OutDir "..\dist"
#endif
#define AppName "R.E.A.L. Mod Manager"
#define AppExe "R.E.A.L. Mod Manager.exe"
#define DataDirName "R.E.A.L. Mod Manager"

[Setup]
AppId={{6C1E2F7A-9B3D-4C55-8E21-5A7D0B4F3C19}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Cavi
AppPublisherURL=https://github.com/urscaviezel/R.E.A.L.-Mod-Manager
AppSupportURL=https://github.com/urscaviezel/R.E.A.L.-Mod-Manager/issues
AppUpdatesURL=https://github.com/urscaviezel/R.E.A.L.-Mod-Manager/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile={#StageDir}\LICENSE
OutputDir={#OutDir}
OutputBaseFilename=R.E.A.L.-Mod-Manager-{#AppVersion}-Setup
SetupIconFile={#StageDir}\assets\logo.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
AppMutex=RealModManager
CloseApplications=yes
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"

[CustomMessages]
de.ModsInstalled=Mit dem R.E.A.L. Mod Manager sind noch Mods installiert.%n%nDie Protokolle für deren saubere Deinstallation bleiben erhalten, wenn du die Daten behältst. Am besten zuerst die Mods im Manager deinstallieren.%n%nTrotzdem fortfahren?
en.ModsInstalled=Mods installed with R.E.A.L. Mod Manager are still present.%n%nThe logs needed to remove them cleanly are kept if you keep the data. Best uninstall the mods in the manager first.%n%nContinue anyway?
fr.ModsInstalled=Des mods installés avec R.E.A.L. Mod Manager sont encore présents.%n%nLes journaux nécessaires à leur désinstallation propre sont conservés si tu gardes les données. Le mieux est de désinstaller d'abord les mods dans le gestionnaire.%n%nContinuer quand même ?
de.DeleteData=Auch die Daten des Managers löschen (Mod-Bibliothek, Protokolle, Sicherungen, Cover)?%n%n%1
en.DeleteData=Also delete the manager's data (mod library, logs, backups, covers)?%n%n%1
fr.DeleteData=Supprimer aussi les données du gestionnaire (bibliothèque de mods, journaux, sauvegardes, jaquettes) ?%n%n%1

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall shellexec

[UninstallDelete]
Type: filesandordirs; Name: "{app}\lang"

[Code]
function DataDir(): String;
begin
  Result := ExpandConstant('{commonappdata}\{#DataDirName}');
end;

function HasActiveJournals(): Boolean;
var
  FindRec: TFindRec;
begin
  Result := False;
  if FindFirst(DataDir() + '\Journals\*', FindRec) then
  begin
    try
      repeat
        if ((FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and (FindRec.Name <> '.') and (FindRec.Name <> '..') and (Copy(FindRec.Name, 1, 1) <> '_') then
          Result := True;
      until Result or not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
  if (not UninstallSilent()) and HasActiveJournals() then
    Result := (MsgBox(CustomMessage('ModsInstalled'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and (not UninstallSilent()) and DirExists(DataDir()) then
    if MsgBox(FmtMessage(CustomMessage('DeleteData'), [DataDir()]), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      DelTree(DataDir(), True, True, True);
end;
