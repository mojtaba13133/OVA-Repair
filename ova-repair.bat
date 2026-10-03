@echo off
rem =====================================================================
rem  OVA-Repair  -  Import broken OVA/OVF into VMware Workstation
rem  ------------------------------------------------------------------
rem  Extracts an OVA/OVF, repairs its VMDK with vmware-vdiskmanager,
rem  and generates a ready-to-boot .vmx so you never have to click
rem  through the "Create New Virtual Machine" wizard again.
rem
rem  Fixes the classic import errors:
rem    * "<disk>.vmdk cannot be opened directly. Open the virtual
rem       machine configuration file (.vmx) instead."
rem    * "The OVF package is invalid and cannot be deployed."
rem    * 7-Zip / tar  "Unexpected end of archive"  on OVA files.
rem
rem  Repo    : https://github.com/<your-user>/ova-repair
rem  License : MIT
rem =====================================================================

setlocal EnableExtensions EnableDelayedExpansion

set "APP_NAME=OVA-Repair"
set "APP_VER=1.0.0"
set "SCRIPT_DIR=%~dp0"
set "CFG=%SCRIPT_DIR%ova-repair.cfg"

rem ---- runtime options (overridable via CLI flags) --------------------
set "SRC="
set "OPT_RAM="
set "OPT_CPU="
set "OPT_GUEST=debian11-64"
set "OPT_FIRMWARE=bios"
set "OPT_CONTROLLER=lsilogic"
set "OPT_OPEN=ask"
set "DO_CONFIG=0"
set "USE_COLOR=1"

rem =====================================================================
rem  Argument parsing
rem =====================================================================
:parse
if "%~1"=="" goto :parsed
set "A=%~1"
if /i "%A%"=="/?"            goto :help
if /i "%A%"=="-h"            goto :help
if /i "%A%"=="--help"        goto :help
if /i "%A%"=="/help"         goto :help
if /i "%A%"=="-v"            goto :version
if /i "%A%"=="--version"     goto :version
if /i "%A%"=="--config"      ( set "DO_CONFIG=1" & shift & goto :parse )
if /i "%A%"=="--reconfigure" ( set "DO_CONFIG=1" & shift & goto :parse )
if /i "%A%"=="--no-color"    ( set "USE_COLOR=0" & shift & goto :parse )
if /i "%A%"=="--ram"         ( set "OPT_RAM=%~2"        & shift & shift & goto :parse )
if /i "%A%"=="--cpu"         ( set "OPT_CPU=%~2"        & shift & shift & goto :parse )
if /i "%A%"=="--guest"       ( set "OPT_GUEST=%~2"      & shift & shift & goto :parse )
if /i "%A%"=="--firmware"    ( set "OPT_FIRMWARE=%~2"   & shift & shift & goto :parse )
if /i "%A%"=="--controller"  ( set "OPT_CONTROLLER=%~2" & shift & shift & goto :parse )
if /i "%A%"=="--open"        ( set "OPT_OPEN=yes" & shift & goto :parse )
if /i "%A%"=="--no-open"     ( set "OPT_OPEN=no"  & shift & goto :parse )
set "SRC=%A%"
shift
goto :parse
:parsed

call :init_color
call :banner

rem =====================================================================
rem  Environment discovery
rem =====================================================================
call :load_cfg
call :ensure_vmware
if errorlevel 1 goto :fail
call :detect_version
call :detect_extractor

if not defined VMW_VER set "VMW_VER=unknown"
if not defined EXTRACTOR set "EXTRACTOR=none"

call :log_step "[1/5] Environment"
call :log_ok  "VMware folder : %VMWARE_DIR%"
call :log_ok  "VMware version: %VMW_VER%  ->  virtualHW %HW_VER%"
call :log_ok  "OVA extractor : %EXTRACTOR%"
echo(

rem =====================================================================
rem  Resolve source (.ova / .ovf)
rem =====================================================================
if not defined SRC set /p "SRC=  Enter full path to the .ova or .ovf file: "
set "SRC=%SRC:"=%"
if not defined SRC goto :err_nofile
if not exist "%SRC%" goto :err_nofile
if exist "%SRC%\" goto :err_isdir

for %%F in ("%SRC%") do (
    set "SRC_DIR=%%~dpF"
    set "SRC_EXT=%%~xF"
    set "SRC_BASE=%%~nF"
)

if /i "%SRC_EXT%"==".ova" goto :do_ova
if /i "%SRC_EXT%"==".ovf" goto :do_ovf
goto :err_badext

rem ---------------------------------------------------------------------
rem  [2] OVA  ->  extract (OVA is just a tar archive)
rem ---------------------------------------------------------------------
:do_ova
if "%EXTRACTOR%"=="none" goto :err_noextractor
set "SEARCH_DIR=%SRC_DIR%extracted"
if not exist "%SEARCH_DIR%" mkdir "%SEARCH_DIR%"
call :log_step "[2/5] Extracting OVA using %EXTRACTOR%"
call :log_info "%SEARCH_DIR%"
if /i "%EXTRACTOR%"=="tar" (
    "%TAREXE%" -xf "%SRC%" -C "%SEARCH_DIR%"
) else (
    "%SEVENZIP%" x "%SRC%" -o"%SEARCH_DIR%" -y >nul 2>&1
)
rem NOTE: An OVA is a tar stream. Many exporters omit the trailing zero
rem padding, so extractors report "Unexpected end of archive" AND still
rem write every member correctly. We therefore ignore the exit code and
rem gate on whether a VMDK actually landed on disk (checked next).
goto :find_vmdk

rem ---------------------------------------------------------------------
rem  [2] OVF  ->  siblings are already on disk, nothing to extract
rem ---------------------------------------------------------------------
:do_ovf
set "SEARCH_DIR=%SRC_DIR%"
call :log_step "[2/5] OVF supplied - using sibling files (no extraction)"
call :log_info "%SEARCH_DIR%"
goto :find_vmdk

rem ---------------------------------------------------------------------
rem  [3] Locate a source VMDK (skip our own previous *-fix.vmdk output)
rem ---------------------------------------------------------------------
:find_vmdk
call :log_step "[3/5] Locating VMDK"
set "VMDK="
for /r "%SEARCH_DIR%" %%F in (*.vmdk) do (
    set "CAND=%%F"
    if not defined VMDK if /i not "!CAND:~-9!"=="-fix.vmdk" set "VMDK=%%F"
)
if not defined VMDK goto :err_novmdk
call :log_ok "Found: !VMDK!"
echo(

rem ---------------------------------------------------------------------
rem  [4] Repair/convert VMDK  (-t 0 = monolithicSparse, single file)
rem ---------------------------------------------------------------------
call :log_step "[4/5] Repairing VMDK (single growable file)"
set "VDM=%VMWARE_DIR%\vmware-vdiskmanager.exe"
if not exist "%VDM%" goto :err_novdm
for %%F in ("%VMDK%") do (
    set "VMDK_DIR=%%~dpF"
    set "VMDK_NAME=%%~nF"
)
set "FIXED=%VMDK_DIR%%VMDK_NAME%-fix.vmdk"
call :log_info "Output: !FIXED!"
if exist "%FIXED%" (
    call :log_warn "Output already exists."
    choice /C YN /M "  Overwrite it"
    if errorlevel 2 goto :cancelled
    del /f /q "%FIXED%" >nul 2>&1
)
"%VDM%" -r "%VMDK%" -t 0 "%FIXED%"
if errorlevel 1 goto :err_convert
call :log_ok "Fixed VMDK ready."
echo(

rem ---------------------------------------------------------------------
rem  [5] Generate the .vmx  (replaces the whole New-VM wizard)
rem ---------------------------------------------------------------------
call :log_step "[5/5] Generating VM configuration (.vmx)"
set "VMNAME=%VMDK_NAME%-fixed"
set "VMX=%VMDK_DIR%%VMNAME%.vmx"
call :log_info "%VMX%"

if not defined OPT_RAM (
    set /p "RAMIN=  RAM in MB [2048]: "
    if "!RAMIN!"=="" ( set "OPT_RAM=2048" ) else ( set "OPT_RAM=!RAMIN!" )
)
if not defined OPT_CPU (
    set /p "CPUIN=  vCPU count [2]: "
    if "!CPUIN!"=="" ( set "OPT_CPU=2" ) else ( set "OPT_CPU=!CPUIN!" )
)

>  "%VMX%" echo .encoding = "UTF-8"
>> "%VMX%" echo config.version = "8"
>> "%VMX%" echo virtualHW.version = "%HW_VER%"
>> "%VMX%" echo virtualHW.productCompatibility = "hosted"
>> "%VMX%" echo displayName = "%VMNAME%"
>> "%VMX%" echo guestOS = "%OPT_GUEST%"
>> "%VMX%" echo nvram = "%VMNAME%.nvram"
>> "%VMX%" echo firmware = "%OPT_FIRMWARE%"
>> "%VMX%" echo memsize = "%OPT_RAM%"
>> "%VMX%" echo numvcpus = "%OPT_CPU%"
>> "%VMX%" echo cpuid.coresPerSocket = "1"
>> "%VMX%" echo vcpu.hotadd = "TRUE"
>> "%VMX%" echo powerType.powerOff = "soft"
>> "%VMX%" echo powerType.powerOn = "soft"
>> "%VMX%" echo powerType.suspend = "soft"
>> "%VMX%" echo powerType.reset = "soft"
>> "%VMX%" echo scsi0.present = "TRUE"
>> "%VMX%" echo scsi0.virtualDev = "%OPT_CONTROLLER%"
>> "%VMX%" echo scsi0:0.present = "TRUE"
>> "%VMX%" echo scsi0:0.fileName = "%FIXED%"
>> "%VMX%" echo scsi0:0.deviceType = "disk"
>> "%VMX%" echo scsi0:0.redo = ""
>> "%VMX%" echo ide1:0.present = "TRUE"
>> "%VMX%" echo ide1:0.deviceType = "cdrom-raw"
>> "%VMX%" echo ide1:0.fileName = "auto detect"
>> "%VMX%" echo ide1:0.autodetect = "TRUE"
>> "%VMX%" echo ethernet0.present = "TRUE"
>> "%VMX%" echo ethernet0.connectionType = "nat"
>> "%VMX%" echo ethernet0.virtualDev = "e1000"
>> "%VMX%" echo ethernet0.addressType = "generated"
>> "%VMX%" echo usb.present = "TRUE"
>> "%VMX%" echo ehci.present = "TRUE"
>> "%VMX%" echo sound.present = "TRUE"
>> "%VMX%" echo sound.autoDetect = "TRUE"
>> "%VMX%" echo sound.fileName = "-1"
>> "%VMX%" echo pciBridge0.present = "TRUE"
>> "%VMX%" echo pciBridge4.present = "TRUE"
>> "%VMX%" echo pciBridge4.virtualDev = "pcieRootPort"
>> "%VMX%" echo pciBridge4.functions = "8"
>> "%VMX%" echo pciBridge5.present = "TRUE"
>> "%VMX%" echo pciBridge5.virtualDev = "pcieRootPort"
>> "%VMX%" echo pciBridge5.functions = "8"
>> "%VMX%" echo pciBridge6.present = "TRUE"
>> "%VMX%" echo pciBridge6.virtualDev = "pcieRootPort"
>> "%VMX%" echo pciBridge6.functions = "8"
>> "%VMX%" echo pciBridge7.present = "TRUE"
>> "%VMX%" echo pciBridge7.virtualDev = "pcieRootPort"
>> "%VMX%" echo pciBridge7.functions = "8"
>> "%VMX%" echo vmci0.present = "TRUE"
>> "%VMX%" echo hpet0.present = "TRUE"
>> "%VMX%" echo svga.vramSize = "268435456"
>> "%VMX%" echo floppy0.present = "FALSE"
>> "%VMX%" echo tools.syncTime = "FALSE"
call :log_ok "VM configuration written."

rem =====================================================================
rem  Summary
rem =====================================================================
echo(
echo %CG%==============================================================%C0%
echo %CG%  SUCCESS%C0%
echo %CG%==============================================================%C0%
echo   Source VMDK : %VMDK%
echo   Fixed  VMDK : %FIXED%
echo   VM config   : %VMX%
echo   Guest / HW  : %OPT_GUEST% / virtualHW %HW_VER% / %OPT_FIRMWARE%
echo   CPU / RAM   : %OPT_CPU% vCPU / %OPT_RAM% MB
echo %CG%==============================================================%C0%
echo(

if /i "%OPT_OPEN%"=="no"  goto :end_ok
if /i "%OPT_OPEN%"=="yes" ( start "" "%VMX%" & goto :end_ok )
choice /C YN /M "  Open the VM in VMware Workstation now"
if errorlevel 2 goto :end_ok
start "" "%VMX%"
goto :end_ok

rem =====================================================================
rem  Terminal states
rem =====================================================================
:cancelled
echo(
call :log_warn "Operation cancelled by user."
goto :end_ok

:end_ok
echo(
pause
endlocal
exit /b 0

rem =====================================================================
rem  Error handlers
rem =====================================================================
:err_nofile
call :log_err "File not found: %SRC%"
goto :fail
:err_isdir
call :log_err "You entered a FOLDER, not a file."
call :log_info "Example: D:\VMs\Leaky-Lab\Leaky.ova"
goto :fail
:err_badext
call :log_err "Unsupported extension '%SRC_EXT%'. Provide a .ova or .ovf file."
goto :fail
:err_noextractor
call :log_err "No OVA extractor available."
call :log_info "Windows 10/11 ship 'tar' at %SystemRoot%\System32\tar.exe."
call :log_info "Otherwise install 7-Zip: https://www.7-zip.org/"
goto :fail
:err_novmdk
call :log_err "No VMDK found under: %SEARCH_DIR%"
call :log_info "If this is an OVA, the archive may be truncated - re-download it."
goto :fail
:err_novdm
call :log_err "vmware-vdiskmanager.exe not found in the configured folder."
call :log_info "Run again with --config to set the correct VMware folder."
goto :fail
:err_convert
call :log_err "VMDK conversion failed."
call :log_info "The source disk is likely corrupt/truncated - re-download the OVA."
goto :fail

:fail
echo(
pause
endlocal
exit /b 1

rem =====================================================================
rem  Subroutines
rem =====================================================================

:banner
echo(
echo %CC%==============================================================%C0%
echo %CC%  %APP_NAME% v%APP_VER%%C0%
echo %CC%  VMware OVA/OVF  ->  fixed VMDK  ->  bootable VM%C0%
echo %CC%==============================================================%C0%
echo(
goto :eof

:init_color
set "ESC="
set "C0=" & set "CB=" & set "CR=" & set "CG=" & set "CY=" & set "CC=" & set "CD="
if "%USE_COLOR%"=="0" goto :eof
for /f %%e in ('echo prompt $E ^| cmd') do set "ESC=%%e"
if not defined ESC goto :eof
set "C0=%ESC%[0m"
set "CB=%ESC%[1m"
set "CR=%ESC%[91m"
set "CG=%ESC%[92m"
set "CY=%ESC%[93m"
set "CC=%ESC%[96m"
set "CD=%ESC%[90m"
goto :eof

:log_step
echo %CB%%~1%C0%
goto :eof
:log_ok
echo   %CG%[ OK ]%C0% %~1
goto :eof
:log_warn
echo   %CY%[WARN]%C0% %~1
goto :eof
:log_err
echo   %CR%[FAIL]%C0% %~1
goto :eof
:log_info
echo   %CD%%~1%C0%
goto :eof

:load_cfg
set "VMWARE_DIR="
if not exist "%CFG%" goto :eof
for /f "usebackq tokens=1,* delims==" %%A in ("%CFG%") do (
    if /i "%%A"=="VMWARE_DIR" set "VMWARE_DIR=%%B"
)
goto :eof

:ensure_vmware
if "%DO_CONFIG%"=="1" set "VMWARE_DIR="
if defined VMWARE_DIR if exist "%VMWARE_DIR%\vmware-vdiskmanager.exe" goto :eof
call :log_step "First-time setup - locate VMware Workstation"
call :autodetect_vmware
if defined VMWARE_DIR if exist "%VMWARE_DIR%\vmware-vdiskmanager.exe" (
    call :log_ok "Autodetected: !VMWARE_DIR!"
    goto :save_cfg
)
:ask_vmware
echo(
call :log_info "Folder that contains vmware-vdiskmanager.exe"
call :log_info "e.g. C:\Program Files\VMware\VMware Workstation"
set "VMWARE_DIR="
set /p "VMWARE_DIR=  VMware install folder: "
set "VMWARE_DIR=%VMWARE_DIR:"=%"
if defined VMWARE_DIR if "!VMWARE_DIR:~-1!"=="\" set "VMWARE_DIR=!VMWARE_DIR:~0,-1!"
if not defined VMWARE_DIR (
    call :log_err "Nothing entered."
    goto :ask_vmware
)
if not exist "!VMWARE_DIR!\vmware-vdiskmanager.exe" (
    call :log_err "vmware-vdiskmanager.exe not found there."
    goto :ask_vmware
)
:save_cfg
> "%CFG%" echo VMWARE_DIR=!VMWARE_DIR!
call :log_ok "Configuration saved to %CFG%"
echo(
goto :eof

:autodetect_vmware
set "VMWARE_DIR="
if not defined VMWARE_DIR if exist "%ProgramFiles%\VMware\VMware Workstation\vmware-vdiskmanager.exe" set "VMWARE_DIR=%ProgramFiles%\VMware\VMware Workstation"
if not defined VMWARE_DIR if exist "%ProgramFiles(x86)%\VMware\VMware Workstation\vmware-vdiskmanager.exe" set "VMWARE_DIR=%ProgramFiles(x86)%\VMware\VMware Workstation"
if not defined VMWARE_DIR for /f "usebackq tokens=2,*" %%A in (`reg query "HKLM\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation" /v InstallPath 2^>nul ^| find "InstallPath"`) do set "VMWARE_DIR=%%B"
if defined VMWARE_DIR if "%VMWARE_DIR:~-1%"=="\" set "VMWARE_DIR=%VMWARE_DIR:~0,-1%"
goto :eof

:detect_version
set "VMW_VER="
set "HW_VER=19"
set "VMAJ=" & set "VMIN="
set "VMWARE_EXE=%VMWARE_DIR%\vmware.exe"
if not exist "%VMWARE_EXE%" set "VMWARE_EXE=%VMWARE_DIR%\vmware-vdiskmanager.exe"
for /f "usebackq delims=" %%V in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "try{(Get-Item '%VMWARE_EXE%').VersionInfo.ProductVersion}catch{''}" 2^>nul`) do set "VMW_VER=%%V"
if not defined VMW_VER goto :eof
for /f "tokens=1,2 delims=." %%a in ("%VMW_VER%") do ( set "VMAJ=%%a" & set "VMIN=%%b" )
if not defined VMAJ goto :eof
if not defined VMIN set "VMIN=0"
rem Map product version -> max virtualHW.version. Undershooting is safe
rem (VMware still opens the VM); overshooting throws "created with a
rem newer version". See VMware KB 1003746.
if %VMAJ% GEQ 17 set "HW_VER=20"
if %VMAJ% GEQ 17 if %VMIN% GEQ 5 set "HW_VER=21"
if %VMAJ% GEQ 17 if %VMIN% GEQ 6 set "HW_VER=22"
if %VMAJ%==16 set "HW_VER=18"
if %VMAJ%==16 if %VMIN% GEQ 1 set "HW_VER=19"
if %VMAJ%==15 set "HW_VER=16"
if %VMAJ%==14 set "HW_VER=14"
goto :eof

:detect_extractor
set "EXTRACTOR="
set "TAREXE=%SystemRoot%\System32\tar.exe"
set "SEVENZIP="
if exist "%TAREXE%" set "EXTRACTOR=tar"
if defined EXTRACTOR goto :eof
if exist "%ProgramFiles%\7-Zip\7z.exe" set "SEVENZIP=%ProgramFiles%\7-Zip\7z.exe"
if not defined SEVENZIP if exist "%ProgramFiles(x86)%\7-Zip\7z.exe" set "SEVENZIP=%ProgramFiles(x86)%\7-Zip\7z.exe"
if defined SEVENZIP set "EXTRACTOR=7-Zip"
goto :eof

:version
echo %APP_NAME% v%APP_VER%
endlocal
exit /b 0

:help
echo(
echo %APP_NAME% v%APP_VER% - Import broken OVA/OVF into VMware Workstation
echo(
echo USAGE:
echo   ova-repair.bat [source] [options]
echo(
echo ARGUMENTS:
echo   source            Full path to a .ova or .ovf file.
echo                     If omitted, you will be prompted for it.
echo(
echo OPTIONS:
echo   --ram ^<MB^>         Memory size in MB          (default: prompt/2048)
echo   --cpu ^<N^>          Number of vCPUs            (default: prompt/2)
echo   --guest ^<id^>       VMware guestOS id          (default: debian11-64)
echo   --firmware ^<t^>     bios ^| efi                 (default: bios)
echo   --controller ^<t^>   lsilogic ^| lsisas1068 ^| pvscsi ^| nvme
echo                                                (default: lsilogic)
echo   --open / --no-open Open the VM afterwards      (default: ask)
echo   --config           Re-run VMware folder setup and exit prompts
echo   --no-color         Disable ANSI colors
echo   -h, --help         Show this help
echo   -v, --version      Show version
echo(
echo EXAMPLES:
echo   ova-repair.bat "D:\VMs\Leaky\Leaky.ova"
echo   ova-repair.bat "D:\VMs\Leaky\Leaky.ova" --ram 4096 --cpu 4 --open
echo   ova-repair.bat --config
echo(
echo NOTES:
echo   * The VMware folder is asked once and cached in ova-repair.cfg
echo     next to this script; later runs reuse it automatically.
echo   * virtualHW.version is chosen from your installed VMware version.
echo   * If the guest will not boot, try --controller lsisas1068 or
echo     --firmware efi to match how the original OVA was built.
echo(
endlocal
exit /b 0
