@echo off
:: ==============================================================================
:: COMPARTDISK 1.3.1 - ASSISTENTE DE REPARO PARA WINDOWS 10 E WINDOWS 11
:: DESENVOLVIDO POR EDSILAS
::
:: Arquitetura hibrida: Batch como interface, navegacao, controle de fluxo,
:: autoelevacao e compatibilidade maxima. PowerShell (7 ou 5.1) como motor de
:: operacoes complexas, WMI/CIM, relatorios e tratamento de erros.
::
:: TODA funcionalidade possui rotina Batch equivalente (rotulos :FB_*), usada
:: automaticamente quando o PowerShell estiver ausente, bloqueado por politica
:: ou quando o modulo .ps1 correspondente nao for encontrado.
::
:: Uso opcional em linha de comando:
::   Launcher.bat /autofix     Reparo geral automatico e sai
::   Launcher.bat /audit       Auditoria completa com relatorios e sai
::   Launcher.bat /report      Gera apenas os relatorios e sai
::   Launcher.bat /clean       Limpeza profunda e sai
::   Launcher.bat /?           Ajuda
::
:: Parametro interno (nao documentado para o operador final):
::   /elevated                 Sentinela de reentrada pos-UAC. Impede laco de
::                             elevacao e ativa o modo protegido de saida.
:: ==============================================================================

::
:: ------------------------------------------------------------------------------
:: CONVENCAO DE TEXTO DA INTERFACE
::
::   Nome do produto ......... COMPARTDISK          (caixa alta: e a marca)
::   Assinatura de autoria ... DESENVOLVIDO POR EDSILAS
::   Titulos de tela ......... Title Case, conectores em minuscula
::                             ex.: "Rede e Conectividade", "Reparo do Sistema"
::   Rotulos de opcao ........ Title Case, mesma regra
::   Parenteses descritivos .. minuscula, exceto siglas e nomes proprios
::                             ex.: "(caches extensos)" mas "(DNS, TCP/IP, Winsock)"
::   Texto corrido e notas ... caixa de frase
::   Marcadores de log ....... caixa alta e largura fixa: [ OK ] [WARN] [ERRO] [INFO]
::
::   Conectores mantidos em minuscula: de, do, da, dos, das, e, em, no, na,
::   para, com, a, o, ao, aos, por, via.
:: ------------------------------------------------------------------------------
::
:: Protecao Global: Impede corrupcao do script por caracteres especiais (!, &, etc)
setlocal EnableExtensions DisableDelayedExpansion
if errorlevel 1 goto SEM_EXTENSOES
chcp 65001 >nul 2>&1

:: ==============================================================================
:: 0. TRACE DE BOOTSTRAP
:: Gravado desde a primeira instrucao util, ANTES de qualquer dependencia.
:: Se o processo morrer de forma abrupta, a ultima linha deste arquivo aponta
:: exatamente o estagio em que a falha ocorreu.
:: ==============================================================================
set "COMPARTDISK_VERSION=1.3.1"
set "COMPARTDISK_ROOT=%~dp0"
set "COMPARTDISK_MODULES=%~dp0Modules"
set "COMPARTDISK_SELF=%~f0"
set "CLI_MODE="
set "COMPARTDISK_GUARD="
set "TRACEFILE=%TEMP%\COMPARTDISK_Bootstrap.log"
:: Consolidacao dos desfechos dos modulos executados nesta sessao.
set "MOD_OK=0"
set "MOD_WARN=0"
set "MOD_ERR=0"
set "MOD_SKIP=0"

:: Recupera o desfecho da execucao anterior antes de sobrescrever o trace
set "ESTAGIO_ANTERIOR="
if exist "%TRACEFILE%" for /f "usebackq delims=" %%a in ("%TRACEFILE%") do set "ESTAGIO_ANTERIOR=%%a"
set "CRASH_ANTERIOR="
if defined ESTAGIO_ANTERIOR echo "%ESTAGIO_ANTERIOR%" | find /i "ENCERRAMENTO NORMAL" >nul 2>&1
if errorlevel 1 if defined ESTAGIO_ANTERIOR set "CRASH_ANTERIOR=%ESTAGIO_ANTERIOR%"

> "%TRACEFILE%" echo COMPARTDISK %COMPARTDISK_VERSION% - DESENVOLVIDO POR EDSILAS - trace de inicializacao
call :TRACE "ESTAGIO 01 - shell inicializado, extensoes ativas"

:: ==============================================================================
:: 1. INICIALIZACAO DA INTERFACE
:: ==============================================================================
title COMPARTDISK %COMPARTDISK_VERSION% - Assistente de Reparo - DESENVOLVIDO POR EDSILAS
reg add "HKCU\Console" /v VirtualTerminalLevel /t REG_DWORD /d 1 /f >nul 2>&1

set "ESC="
for /F %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
if defined ESC goto CORES_ANSI

:: Sem sequencia de escape disponivel (console legado, EDR bloqueando spawn de
:: cmd): degrada para texto puro em vez de imprimir lixo do tipo "[1;32;44m".
call :TRACE "ESTAGIO 02 - ANSI indisponivel, usando saida em texto puro"
set "C_VERDE=" & set "C_AMARELO=" & set "C_VERMELHO="
set "C_CIANO=" & set "C_BRANCO=" & set "C_RESET=" & set "C_CINZA="
set "C_TITULO=" & set "C_TEXTO="
goto CORES_PRONTAS

:CORES_ANSI
:: Paleta sobria: o fundo do console e preservado (sem ;44m). Cor usada com
:: parcimonia - cinza para estrutura, ciano apenas em destaques pontuais,
:: verde/amarelo/vermelho reservados a resultado de operacao.
set "C_TITULO=%ESC%[97m"    & set "C_TEXTO=%ESC%[37m"     & set "C_CINZA=%ESC%[90m"
set "C_CIANO=%ESC%[36m"     & set "C_VERDE=%ESC%[32m"     & set "C_AMARELO=%ESC%[33m"
set "C_VERMELHO=%ESC%[91m"  & set "C_BRANCO=%ESC%[97m"    & set "C_RESET=%ESC%[0m"

:CORES_PRONTAS
:: Fundo preto com texto cinza claro: menor contraste, menor fadiga visual
color 07
call :TRACE "ESTAGIO 03 - interface pronta"

:: ==============================================================================
:: 2. AUTO-ELEVACAO DE PRIVILEGIOS (UAC)
:: ==============================================================================

:: --- 2.1 Consome a sentinela de reentrada, se presente
if /i "%~1"=="/elevated" (
    set "COMPARTDISK_GUARD=1"
    shift
)
if defined COMPARTDISK_GUARD call :TRACE "ESTAGIO 04 - reentrada pos-UAC detectada (modo protegido)"

:: --- 2.2 Deteccao de privilegio em camadas
::     "net session" sozinho NAO serve: retorna erro quando o servico Server
::     (LanmanServer) esta parado ou desabilitado, o que e comum em Windows Home
::     e em imagens corporativas endurecidas. Nesse cenario um administrador
::     legitimo era classificado como usuario comum.
set "IS_ADMIN=0"

fltmc >nul 2>&1
if not errorlevel 1 set "IS_ADMIN=1"

if "%IS_ADMIN%"=="0" (
    net session >nul 2>&1
    if not errorlevel 1 set "IS_ADMIN=1"
)

if "%IS_ADMIN%"=="0" (
    reg add "HKLM\SOFTWARE\CompartDiskElevTest" /f >nul 2>&1
    if not errorlevel 1 (
        reg delete "HKLM\SOFTWARE\CompartDiskElevTest" /f >nul 2>&1
        set "IS_ADMIN=1"
    )
)

call :TRACE "ESTAGIO 05 - deteccao de privilegio concluida (IS_ADMIN=%IS_ADMIN%)"

if "%IS_ADMIN%"=="1" goto ELEVACAO_OK

:: --- 2.3 Ja voltamos do UAC e ainda assim nao somos administradores.
::     Prosseguir degradado e MUITO melhor que reelevar em laco infinito.
if defined COMPARTDISK_GUARD (
    call :TRACE "ESTAGIO 05b - elevacao recusada ou incompleta, seguindo degradado"
    echo.
    echo   %C_AMARELO%[AVISO]%C_RESET% %C_TEXTO%A ferramenta nao esta em contexto administrativo.%C_RESET%
    echo   %C_CINZA%        Funcoes que exigem privilegio serao recusadas pelo Windows.%C_RESET%
    echo.
    pause
    goto ELEVACAO_OK
)

:: --- 2.4 Solicita elevacao
call :TRACE "ESTAGIO 06 - solicitando elevacao via UAC"
echo Solicitando privilegios de Administrador...
:: %~1 em vez de %* : remove as aspas do argumento e limita o repasse ao unico
:: parametro que o Launcher interpreta (secao 3.6 le somente %~1). Um argumento
:: entre aspas em %* fechava a cadeia de aspas montada no VBS abaixo e a
:: elevacao falhava sem explicacao.
set "ELEV_FWD=%~1"
set "COMPARTDISK_VBS=%TEMP%\compartdisk_elevate_%RANDOM%.vbs"

:: O comando reexecutado e:  cmd /d /c ""<script>" /elevated <args> & pause"
:: O "& pause" e a rede de seguranca: se o Batch morrer de forma abrupta na
:: instancia elevada, a janela permanece aberta exibindo o erro em vez de
:: fechar instantaneamente. O "&" e emitido como Chr(38) e a concatenacao usa
:: "+", para que nenhum caractere especial precise passar pelo parser do CMD.
> "%COMPARTDISK_VBS%" echo Set UAC = CreateObject^("Shell.Application"^)
>> "%COMPARTDISK_VBS%" echo q = Chr^(34^)
>> "%COMPARTDISK_VBS%" echo alvo = q + "%COMPARTDISK_SELF%" + q
>> "%COMPARTDISK_VBS%" echo linha = "/d /c " + q + alvo + " /elevated %ELEV_FWD% " + Chr^(38^) + " pause" + q
>> "%COMPARTDISK_VBS%" echo UAC.ShellExecute "%COMSPEC%", linha, "%COMPARTDISK_ROOT%", "runas", 1

:: cscript explicito: nao depende da associacao do tipo .vbs, que costuma estar
:: redirecionada ou bloqueada por politica em parque corporativo.
cscript //nologo //B "%COMPARTDISK_VBS%" >nul 2>&1
if not errorlevel 1 goto ELEVACAO_ENVIADA

call :TRACE "ESTAGIO 06b - WSH indisponivel, tentando elevacao via PowerShell"
:: Este caminho repassava apenas '/elevated' e descartava o parametro original.
:: Consequencia: numa maquina sem Windows Script Host, "Launcher.bat /autofix"
:: reabria elevado no MENU em vez de executar o reparo, e a execucao
:: desassistida ficava parada esperando alguem digitar.
if defined ELEV_FWD powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:COMPARTDISK_SELF -ArgumentList '/elevated','%ELEV_FWD%' -Verb RunAs" >nul 2>&1
if not defined ELEV_FWD powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:COMPARTDISK_SELF -ArgumentList '/elevated' -Verb RunAs" >nul 2>&1
if not errorlevel 1 goto ELEVACAO_ENVIADA

call :TRACE "ESTAGIO 06c - falha em todos os metodos de elevacao"
echo.
echo   %C_VERMELHO%[ERRO]%C_RESET%  %C_TEXTO%Nao foi possivel solicitar elevacao automaticamente.%C_RESET%
echo         O Windows Script Host e o PowerShell estao ambos indisponiveis.
echo.
echo         Clique com o botao direito em Launcher.bat e escolha
echo         "Executar como administrador".
echo.
pause
del "%COMPARTDISK_VBS%" >nul 2>&1
exit /b 1

:ELEVACAO_ENVIADA
call :TRACE "ESTAGIO 07 - instancia elevada solicitada, encerrando instancia atual"
:: EVIDENCIA: no log de 13/08/2026 as duas sessoes abriram com "A execucao
:: anterior terminou de forma anormal ... ESTAGIO 07". O encerramento apos o
:: handoff de elevacao e INTENCIONAL, mas a ultima linha do trace nao continha
:: o marcador de saida limpa e a instancia elevada o lia como queda. O marcador
:: passa a ser gravado tambem aqui.
call :TRACE "ENCERRAMENTO NORMAL - instancia nao elevada encerrada apos handoff de elevacao"
ping -n 2 127.0.0.1 >nul 2>&1
del "%COMPARTDISK_VBS%" >nul 2>&1
exit /b 0

:ELEVACAO_OK
call :TRACE "ESTAGIO 08 - contexto administrativo confirmado"

:: ==============================================================================
:: 2.5 GESTAO DINAMICA DO LOG
:: Cadeia de fallback: pasta do script -> Desktop -> TEMP. O teste e de escrita
:: real, nao de existencia, porque pendrive protegido e share de rede aceitam
:: "exist" mas recusam gravacao.
:: ==============================================================================
set "LOGDIR=%COMPARTDISK_ROOT%"
call :TESTAR_ESCRITA "%LOGDIR%"
if not errorlevel 1 goto LOG_PRONTO

set "LOGDIR=%USERPROFILE%\Desktop\"
call :TESTAR_ESCRITA "%LOGDIR%"
if not errorlevel 1 goto LOG_PRONTO

set "LOGDIR=%TEMP%\"
call :TESTAR_ESCRITA "%LOGDIR%"
if not errorlevel 1 goto LOG_PRONTO

call :TRACE "ESTAGIO 09 - FALHA: nenhum diretorio gravavel encontrado"
echo.
echo   %C_VERMELHO%[ERRO]%C_RESET%  %C_TEXTO%Nao ha diretorio gravavel para o log.%C_RESET%
echo         Testados: pasta do script, Desktop e TEMP.
echo.
pause
exit /b 1

:LOG_PRONTO
set "LOGFILE=%LOGDIR%Relatorio_Manutencao.txt"
call :TRACE "ESTAGIO 09 - log gravavel em %LOGDIR%"

:: ==============================================================================
:: 3. PRE-FLIGHT CHECKS (AUDITORIA DE AMBIENTE - BLOCOS EXPLICITOS)
:: ==============================================================================

:: --- 3.1 Selecao do motor PowerShell: pwsh 7 > powershell 5.1 > Batch puro
set "PS_EXE="
set "PS_KIND=Batch"

if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PS_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PS_EXE if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PS_EXE=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PS_EXE for /f "delims=" %%i in ('where pwsh.exe 2^>nul') do set "PS_EXE=%%i"
if defined PS_EXE set "PS_KIND=PowerShell 7"

if not defined PS_EXE (
    powershell -NoProfile -Command "exit 0" >nul 2>&1
    if not errorlevel 1 (
        set "PS_EXE=powershell.exe"
        set "PS_KIND=Windows PowerShell 5.1"
    )
)

:: Validacao real do motor escolhido (ExecutionPolicy, AppLocker, WDAC):
:: o executavel pode existir e mesmo assim recusar-se a executar scripts.
if defined PS_EXE (
    "%PS_EXE%" -NoProfile -Command "exit 0" >nul 2>&1
    if errorlevel 1 (
        set "PS_EXE="
        set "PS_KIND=Batch"
    )
)

set "HAS_PS=1"
if not defined PS_EXE set "HAS_PS=0"
call :TRACE "ESTAGIO 10 - motor selecionado: %PS_KIND%"

:: --- 3.2 Presenca do diretorio de modulos
set "HAS_MODULES=1"
if not exist "%COMPARTDISK_MODULES%\Core.ps1" set "HAS_MODULES=0"

:: --- 3.3 Demais ferramentas nativas (blocos explicitos)
:: A presenca do binario e verificada primeiro, com "where", que e barato e nao
:: produz efeito colateral. So quando o binario existe o teste funcional roda.
:: Antes, os quatro comandos eram invocados sempre: em maquina sem winget o
:: shell ainda pagava a resolucao do comando, e "manage-bde -status" sem alvo
:: enumera TODOS os volumes, o que custa segundos no arranque.
set "HAS_WINGET=0"
where winget >nul 2>&1
if errorlevel 1 goto PF_WMIC
winget --info >nul 2>&1
if not errorlevel 1 set "HAS_WINGET=1"

:PF_WMIC
:: WMIC foi removido das builds mais recentes do Windows 11. Ausente e um
:: estado legitimo, nao uma falha.
set "HAS_WMIC=0"
where wmic >nul 2>&1
if errorlevel 1 goto PF_PNP
wmic os get caption >nul 2>&1
if not errorlevel 1 set "HAS_WMIC=1"

:PF_PNP
set "HAS_PNP=0"
where pnputil >nul 2>&1
if errorlevel 1 goto PF_BDE
pnputil /? >nul 2>&1
if not errorlevel 1 set "HAS_PNP=1"

:PF_BDE
:: "manage-bde -status" exige privilegio administrativo. No caminho degradado
:: (UAC recusado) ele falhava por permissao, e o BitLocker era classificado
:: como ausente numa maquina que o tem - o menu passava a oferecer o fallback
:: errado. Sem privilegio, a presenca do binario e o que se pode afirmar.
set "HAS_BDE=0"
where manage-bde >nul 2>&1
if errorlevel 1 goto PF_FIM
if "%IS_ADMIN%"=="1" goto PF_BDE_TESTE
:: Sem privilegio, a presenca do binario e tudo o que se pode afirmar.
set "HAS_BDE=1"
goto PF_FIM

:PF_BDE_TESTE
manage-bde -status >nul 2>&1
if not errorlevel 1 set "HAS_BDE=1"

:PF_FIM
call :TRACE "ESTAGIO 11 - pre-flight concluido (PS=%HAS_PS% MOD=%HAS_MODULES% WINGET=%HAS_WINGET% WMIC=%HAS_WMIC% PNP=%HAS_PNP% BDE=%HAS_BDE%)"

:: --- 3.4 Identificador unico de sessao (compartilhado com os modulos)
::     Evita FOR /F com caminhos entre aspas (parser do CMD e instavel nesse caso)
set "COMPARTDISK_SESSION="
if "%HAS_PS%"=="0" goto SESSAO_FALLBACK
"%PS_EXE%" -NoProfile -NoLogo -Command "Get-Date -Format yyyyMMdd_HHmmss" > "%TEMP%\compartdisk_session.tmp" 2>nul
if exist "%TEMP%\compartdisk_session.tmp" set /p COMPARTDISK_SESSION=<"%TEMP%\compartdisk_session.tmp"
del "%TEMP%\compartdisk_session.tmp" >nul 2>&1
:SESSAO_FALLBACK
if not defined COMPARTDISK_SESSION set "COMPARTDISK_SESSION=S%RANDOM%%RANDOM%"

:: --- 3.5 Contexto exportado para os modulos PowerShell
set "COMPARTDISK_LOGDIR=%LOGDIR%"
set "COMPARTDISK_LOGFILE=%LOGFILE%"
set "COMPARTDISK_ENGINE=%PS_KIND%"
set "COMPARTDISK_TRACE=%TRACEFILE%"

echo =============================================== >> "%LOGFILE%"
call :LOG_MSG "INFO" "COMPARTDISK %COMPARTDISK_VERSION% - DESENVOLVIDO POR EDSILAS"
call :LOG_MSG "INFO" "SESSAO INICIADA - PC: %COMPUTERNAME% - USER: %USERNAME%"
call :LOG_MSG "INFO" "Motor de execucao: %PS_KIND% - Sessao: %COMPARTDISK_SESSION%"
call :LOG_MSG "INFO" "Contexto administrativo: %IS_ADMIN% - Diretorio de log: %LOGDIR%"
if "%HAS_PS%"=="0" call :LOG_MSG "WARN" "PowerShell bloqueado/ausente. Fallbacks Batch ativados."
if "%HAS_MODULES%"=="0" call :LOG_MSG "WARN" "Pasta Modules nao encontrada. Operando somente com rotinas Batch."
if defined CRASH_ANTERIOR call :LOG_MSG "WARN" "A execucao anterior terminou de forma anormal em: %CRASH_ANTERIOR%"
call :TRACE "ESTAGIO 12 - cabecalho de log gravado"

:: --- 3.6 Modo linha de comando (execucao desassistida)
if "%~1"=="" goto MENU_PRINCIPAL
set "CLI_MODE=1"
if /i "%~1"=="/autofix" goto CLI_AUTOFIX
if /i "%~1"=="/audit"   goto CLI_AUDIT
if /i "%~1"=="/report"  goto CLI_REPORT
if /i "%~1"=="/clean"   goto CLI_CLEAN
if /i "%~1"=="/?"       goto CLI_HELP
if /i "%~1"=="/help"    goto CLI_HELP
set "CLI_MODE="
call :LOG_MSG "WARN" "Parametro desconhecido: %~1"
goto MENU_PRINCIPAL

:CLI_AUTOFIX
call :MOD_AUTO_FIX_CORE
goto SAIR
:CLI_AUDIT
call :MOD_AUDITORIA_COMPLETA_CLI
goto SAIR
:CLI_REPORT
call :MOD_RELATORIO_CLI
goto SAIR
:CLI_CLEAN
call :MOD_TEMP_LOGS_SILENT
goto SAIR
:CLI_HELP
echo.
echo   %C_TITULO%COMPARTDISK%C_RESET%  %C_CINZA%%COMPARTDISK_VERSION%%C_RESET%
echo   %C_CINZA%Parametros de Linha de Comando%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%/autofix%C_RESET%   %C_TEXTO%Executa o reparo geral automatico e encerra%C_RESET%
echo    %C_CIANO%/audit%C_RESET%     %C_TEXTO%Executa a auditoria completa e gera os relatorios%C_RESET%
echo    %C_CIANO%/report%C_RESET%    %C_TEXTO%Gera apenas os relatorios consolidados%C_RESET%
echo    %C_CIANO%/clean%C_RESET%     %C_TEXTO%Executa a limpeza profunda%C_RESET%
echo    %C_CIANO%/?%C_RESET%         %C_TEXTO%Exibe esta ajuda%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
pause
exit /b 0

:: ==============================================================================
:: MENU PRINCIPAL
:: ==============================================================================
:MENU_PRINCIPAL
cls
echo.
echo   %C_TITULO%COMPARTDISK%C_RESET%  %C_CINZA%%COMPARTDISK_VERSION%%C_RESET%
echo   %C_CINZA%Assistente de Reparo%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Reparo Geral Automatico (One-Click Fix)%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Atualizar Programas (Winget)%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Rede, Internet e Conectividade%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Otimizacao, Limpeza Profunda e Privacidade%C_RESET%
echo    %C_CIANO%[5]%C_RESET%  %C_TEXTO%Reparo do Sistema, Windows Update e Explorer%C_RESET%
echo    %C_CIANO%[6]%C_RESET%  %C_TEXTO%Contas, Permissoes e Seguranca%C_RESET%
echo    %C_CIANO%[7]%C_RESET%  %C_TEXTO%Discos, Drivers e Auditoria de Hardware%C_RESET%
echo    %C_CIANO%[8]%C_RESET%  %C_TEXTO%Diagnostico Avancado e Relatorios (TXT/CSV/JSON/HTML)%C_RESET%
echo    %C_CIANO%[9]%C_RESET%  %C_TEXTO%Ambiente de Execucao e Capacidades%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Sair e Salvar Relatorio%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%Motor:%C_RESET% %C_TEXTO%%PS_KIND%%C_RESET%
echo   %C_CINZA%Log:%C_RESET%   %C_TEXTO%%LOGFILE%%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 1234567890 /n /m "  Opcao: "

if errorlevel 10 goto SAIR
if errorlevel 9 goto MENU_AMBIENTE
if errorlevel 8 goto MENU_DIAGNOSTICO
if errorlevel 7 goto MENU_HARDWARE
if errorlevel 6 goto MENU_SEGURANCA
if errorlevel 5 goto MENU_REPARO
if errorlevel 4 goto MENU_OTIMIZACAO
if errorlevel 3 goto MENU_REDE
if errorlevel 2 goto MOD_WINGET_MENU
if errorlevel 1 goto MOD_AUTO_FIX
:: Rede de seguranca: CHOICE interrompido (Ctrl+C) retorna 0 e nao deve cair no submenu seguinte
goto MENU_PRINCIPAL

:: ==============================================================================
:: SUBMENUS
:: ==============================================================================
:MENU_REDE
cls
echo.
echo   %C_TITULO%Rede e Conectividade%C_RESET%
echo   %C_CINZA%COMPARTDISK %COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Reset Completo (DNS, Winsock, TCP/IP, ARP, IPv6, proxy)%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Restaurar Arquivo Hosts%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Restaurar Firewall%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Diagnostico de Adaptadores, DNS, DHCP, MTU e Rotas%C_RESET%
echo    %C_CIANO%[5]%C_RESET%  %C_TEXTO%Teste de Conectividade e Resolucao de Nomes%C_RESET%
echo    %C_CIANO%[6]%C_RESET%  %C_TEXTO%Configuracao de Proxy%C_RESET%
echo    %C_CIANO%[7]%C_RESET%  %C_TEXTO%Diagnostico Wi-Fi%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 12345670 /n /m "  Opcao: "
:: MENU_OPC congela a tecla escolhida. "if errorlevel N" testa ">= N", e cada
:: "call" abaixo devolve o codigo de saida do modulo (0/1/2/3): sem congelar,
:: um modulo que retorna WARN reativava os testes de baixo e executava opcoes
:: que o usuario nao escolheu.
set "MENU_OPC=%errorlevel%"
if "%MENU_OPC%"=="8" goto MENU_PRINCIPAL
if "%MENU_OPC%"=="7" call :MOD_REDE_WIFI
if "%MENU_OPC%"=="6" call :MOD_REDE_PROXY
if "%MENU_OPC%"=="5" call :MOD_REDE_TESTE
if "%MENU_OPC%"=="4" call :MOD_REDE_INFO
if "%MENU_OPC%"=="3" call :MOD_FIREWALL
if "%MENU_OPC%"=="2" call :MOD_REDE_HOSTS
if "%MENU_OPC%"=="1" call :MOD_REDE_RESET
pause & goto MENU_REDE

:MENU_OTIMIZACAO
cls
echo.
echo   %C_TITULO%Otimizacao e Limpeza%C_RESET%
echo   %C_CINZA%COMPARTDISK %COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Limpeza Customizada (caches extensos, perfis, updates)%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Desativar Telemetria%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Aplicar Perfil Desempenho Maximo%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Simular Limpeza (mostra o espaco recuperavel sem apagar nada)%C_RESET%
echo    %C_CIANO%[5]%C_RESET%  %C_TEXTO%Limpeza de Navegadores (Edge, Chrome, Brave, Firefox)%C_RESET%
echo    %C_CIANO%[6]%C_RESET%  %C_TEXTO%Analise de Desempenho (energia, inicializacao, processos, servicos)%C_RESET%
echo    %C_CIANO%[7]%C_RESET%  %C_TEXTO%Restaurar Telemetria ao Padrao do Windows%C_RESET%
echo    %C_CIANO%[8]%C_RESET%  %C_TEXTO%Restaurar Plano de Energia Equilibrado%C_RESET%
echo    %C_CIANO%[9]%C_RESET%  %C_TEXTO%Desbloat do Windows (aplicativos, servicos, tarefas, componentes)%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 1234567890 /n /m "  Opcao: "
set "MENU_OPC=%errorlevel%"
if "%MENU_OPC%"=="10" goto MENU_PRINCIPAL
if "%MENU_OPC%"=="9" goto MENU_DEBLOAT
if "%MENU_OPC%"=="8" call :MOD_PERF_BALANCED
if "%MENU_OPC%"=="7" call :MOD_TELEMETRIA_ON
if "%MENU_OPC%"=="6" call :MOD_PERF_ANALISE
if "%MENU_OPC%"=="5" call :MOD_LIMPEZA_NAVEGADORES
if "%MENU_OPC%"=="4" call :MOD_LIMPEZA_SIMULACAO
if "%MENU_OPC%"=="3" call :MOD_PERFORMANCE
if "%MENU_OPC%"=="2" call :MOD_TELEMETRIA
if "%MENU_OPC%"=="1" call :MOD_TEMP_LOGS
pause & goto MENU_OTIMIZACAO

:MENU_DEBLOAT
cls
echo.
echo   %C_TITULO%Desbloat do Windows%C_RESET%
echo   %C_CINZA%COMPARTDISK %COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo   %C_TEXTO%Tres niveis, do mais conservador ao mais invasivo. Comece sempre pela%C_RESET%
echo   %C_TEXTO%simulacao: ela mostra exatamente o que seria alterado, sem alterar nada.%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Simular Desbloat (nao altera nada)%C_RESET%   %C_CINZA%(comece aqui)%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Desbloat Seguro%C_RESET%   %C_CINZA%(recomendado)%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Desbloat Moderado (inclui Xbox, midia, fotos, email)%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Desbloat Avancado (inclui busca do Iniciar e ResetBase)%C_RESET%
echo    %C_CIANO%[5]%C_RESET%  %C_TEXTO%Remover Somente Aplicativos%C_RESET%
echo    %C_CIANO%[6]%C_RESET%  %C_TEXTO%Ajustar Servicos e Tarefas Agendadas%C_RESET%
echo    %C_CIANO%[7]%C_RESET%  %C_TEXTO%Privacidade e Ajustes Opcionais%C_RESET%
echo    %C_CIANO%[8]%C_RESET%  %C_TEXTO%Limpar Componentes Obsoletos (WinSxS)%C_RESET%
echo    %C_CIANO%[9]%C_RESET%  %C_TEXTO%Backup, Ponto de Restauracao e Reverter Alteracoes%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 1234567890 /n /m "  Opcao: "
set "MENU_OPC=%errorlevel%"
if "%MENU_OPC%"=="10" goto MENU_OTIMIZACAO
if "%MENU_OPC%"=="9" goto MENU_DEBLOAT_REVERSAO
if "%MENU_OPC%"=="8" call :MOD_DEBLOAT_COMPONENTES
if "%MENU_OPC%"=="7" call :MOD_DEBLOAT_PRIVACIDADE
if "%MENU_OPC%"=="6" call :MOD_DEBLOAT_SERVICOS
if "%MENU_OPC%"=="5" call :MOD_DEBLOAT_APPS
if "%MENU_OPC%"=="4" call :MOD_DEBLOAT_AVANCADO
if "%MENU_OPC%"=="3" call :MOD_DEBLOAT_MODERADO
if "%MENU_OPC%"=="2" call :MOD_DEBLOAT_SEGURO
if "%MENU_OPC%"=="1" call :MOD_DEBLOAT_SIMULAR
pause & goto MENU_DEBLOAT

:MENU_DEBLOAT_REVERSAO
cls
echo.
echo   %C_TITULO%Backup e Reversao do Desbloat%C_RESET%
echo   %C_CINZA%COMPARTDISK %COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo   %C_TEXTO%Servicos, tarefas e ajustes de registro voltam ao valor exato anterior.%C_RESET%
echo   %C_TEXTO%Aplicativos removidos precisam ser reinstalados pela Microsoft Store:%C_RESET%
echo   %C_TEXTO%o Windows nao guarda o pacote original no disco apos a remocao.%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Criar Ponto de Restauracao Agora%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Registrar Estado Atual (backup, nao altera nada)%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Simular Reversao%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Reverter Alteracoes do Desbloat%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 12340 /n /m "  Opcao: "
set "MENU_OPC=%errorlevel%"
if "%MENU_OPC%"=="5" goto MENU_DEBLOAT
if "%MENU_OPC%"=="4" call :MOD_DEBLOAT_REVERTER
if "%MENU_OPC%"=="3" call :MOD_DEBLOAT_REVERTER_SIMULAR
if "%MENU_OPC%"=="2" call :MOD_DEBLOAT_BACKUP
if "%MENU_OPC%"=="1" call :MOD_DEBLOAT_PONTO
pause & goto MENU_DEBLOAT_REVERSAO

:MENU_REPARO
cls
echo.
echo   %C_TITULO%Reparo Critico%C_RESET%
echo   %C_CINZA%COMPARTDISK %COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Reparo Profundo (DISM ScanHealth + RestoreHealth + SFC)%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Destravar Windows Update (reset completo dos componentes)%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Destravar Fila de Impressao%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Reiniciar Windows Explorer%C_RESET%
echo    %C_CIANO%[5]%C_RESET%  %C_TEXTO%Agendar Verificacao de Disco (CHKDSK)%C_RESET%
echo    %C_CIANO%[6]%C_RESET%  %C_TEXTO%Status e Historico do Windows Update%C_RESET%
echo    %C_CIANO%[7]%C_RESET%  %C_TEXTO%Procurar Atualizacoes Pendentes%C_RESET%
echo    %C_CIANO%[8]%C_RESET%  %C_TEXTO%Limpar Somente o Cache do Windows Update%C_RESET%
echo    %C_CIANO%[9]%C_RESET%  %C_TEXTO%Reconstruir Cache de Icones e Miniaturas%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 1234567890 /n /m "  Opcao: "
set "MENU_OPC=%errorlevel%"
if "%MENU_OPC%"=="10" goto MENU_PRINCIPAL
if "%MENU_OPC%"=="9" call :MOD_EXPLORER_CACHE
if "%MENU_OPC%"=="8" call :MOD_UPDATE_CACHE
if "%MENU_OPC%"=="7" call :MOD_UPDATE_BUSCAR
if "%MENU_OPC%"=="6" call :MOD_UPDATE_STATUS
if "%MENU_OPC%"=="5" call :MOD_CHKDSK
if "%MENU_OPC%"=="4" call :MOD_EXPLORER
if "%MENU_OPC%"=="3" call :MOD_SPOOLER
if "%MENU_OPC%"=="2" call :MOD_UPDATE_RESET
if "%MENU_OPC%"=="1" call :MOD_SFC_DISM
pause & goto MENU_REPARO

:MENU_SEGURANCA
cls
echo.
echo   %C_TITULO%Seguranca e Contas%C_RESET%
echo   %C_CINZA%COMPARTDISK %COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Resetar GPO Local%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Gerenciar Contas Locais%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Forcar Varredura Defender%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Assumir Controle de Pasta/Arquivo (Takeown)%C_RESET%
echo    %C_CIANO%[5]%C_RESET%  %C_TEXTO%Postura de Seguranca (Secure Boot, TPM, VBS, LSA, UAC, SmartScreen)%C_RESET%
echo    %C_CIANO%[6]%C_RESET%  %C_TEXTO%Status Completo do Defender e Antivirus Instalados%C_RESET%
echo    %C_CIANO%[7]%C_RESET%  %C_TEXTO%Varredura Completa do Defender%C_RESET%
echo    %C_CIANO%[8]%C_RESET%  %C_TEXTO%Exclusoes e Historico de Ameacas%C_RESET%
echo    %C_CIANO%[9]%C_RESET%  %C_TEXTO%Auditoria de Contas, Grupos e Falhas de Logon%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 1234567890 /n /m "  Opcao: "
set "MENU_OPC=%errorlevel%"
if "%MENU_OPC%"=="10" goto MENU_PRINCIPAL
if "%MENU_OPC%"=="9" call :MOD_USERS_AUDIT
if "%MENU_OPC%"=="8" call :MOD_DEFENDER_EXCL
if "%MENU_OPC%"=="7" call :MOD_DEFENDER_FULL
if "%MENU_OPC%"=="6" call :MOD_DEFENDER_STATUS
if "%MENU_OPC%"=="5" call :MOD_SEGURANCA_STATUS
if "%MENU_OPC%"=="4" call :MOD_TAKEOWN
if "%MENU_OPC%"=="3" call :MOD_DEFENDER
if "%MENU_OPC%"=="2" call :MOD_USERS
if "%MENU_OPC%"=="1" call :MOD_GPO_RESET
pause & goto MENU_SEGURANCA

:MENU_HARDWARE
cls
echo.
echo   %C_TITULO%Hardware e Discos%C_RESET%
echo   %C_CINZA%COMPARTDISK %COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Saude Fisica dos Discos%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Relatorio de Bateria%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Status BitLocker%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Backup de Drivers%C_RESET%
echo    %C_CIANO%[5]%C_RESET%  %C_TEXTO%Auditoria de Sistema%C_RESET%
echo    %C_CIANO%[6]%C_RESET%  %C_TEXTO%Inventario Completo (CPU, RAM, GPU, monitores, USB, PCI, TPM)%C_RESET%
echo    %C_CIANO%[7]%C_RESET%  %C_TEXTO%Contadores de Confiabilidade e Desgaste dos Discos%C_RESET%
echo    %C_CIANO%[8]%C_RESET%  %C_TEXTO%Volumes, Espaco e Copias de Sombra%C_RESET%
echo    %C_CIANO%[9]%C_RESET%  %C_TEXTO%Drivers com Problema e Sem Assinatura Digital%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 1234567890 /n /m "  Opcao: "
set "MENU_OPC=%errorlevel%"
if "%MENU_OPC%"=="10" goto MENU_PRINCIPAL
if "%MENU_OPC%"=="9" call :MOD_DRIVERS_PROBLEMAS
if "%MENU_OPC%"=="8" call :MOD_VOLUMES
if "%MENU_OPC%"=="7" call :MOD_SMART_DETALHE
if "%MENU_OPC%"=="6" call :MOD_HARDWARE_FULL
if "%MENU_OPC%"=="5" call :MOD_SYSINFO
if "%MENU_OPC%"=="4" call :MOD_DRIVERS
if "%MENU_OPC%"=="3" call :MOD_BITLOCKER
if "%MENU_OPC%"=="2" call :MOD_BATTERY
if "%MENU_OPC%"=="1" call :MOD_SMART
pause & goto MENU_HARDWARE

:MENU_DIAGNOSTICO
cls
echo.
echo   %C_TITULO%Diagnostico Avancado e Relatorios%C_RESET%
echo   %C_CINZA%COMPARTDISK %COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Auditoria Completa + Relatorios (TXT, CSV, JSON, HTML)%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Auditoria Rapida%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Consolidar Relatorio da Sessao Atual%C_RESET%
echo    %C_CIANO%[4]%C_RESET%  %C_TEXTO%Eventos Criticos (7 dias)%C_RESET%
echo    %C_CIANO%[5]%C_RESET%  %C_TEXTO%Eventos Criticos (30 dias)%C_RESET%
echo    %C_CIANO%[6]%C_RESET%  %C_TEXTO%Inventario de Aplicativos Instalados%C_RESET%
echo    %C_CIANO%[7]%C_RESET%  %C_TEXTO%Licenciamento do Windows%C_RESET%
echo    %C_CIANO%[8]%C_RESET%  %C_TEXTO%Exportar Inventario de Drivers%C_RESET%
echo    %C_CIANO%[9]%C_RESET%  %C_TEXTO%Abrir o Ultimo Relatorio Gerado%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 1234567890 /n /m "  Opcao: "
set "MENU_OPC=%errorlevel%"
if "%MENU_OPC%"=="10" goto MENU_PRINCIPAL
if "%MENU_OPC%"=="9" call :MOD_RELATORIO_ABRIR
if "%MENU_OPC%"=="8" call :MOD_DRIVERS_EXPORT
if "%MENU_OPC%"=="7" call :MOD_LICENCA
if "%MENU_OPC%"=="6" call :MOD_SOFTWARE
if "%MENU_OPC%"=="5" call :MOD_EVENTOS_30
if "%MENU_OPC%"=="4" call :MOD_EVENTOS_7
if "%MENU_OPC%"=="3" call :MOD_RELATORIO
if "%MENU_OPC%"=="2" call :MOD_AUDITORIA_RAPIDA
if "%MENU_OPC%"=="1" call :MOD_AUDITORIA_COMPLETA
pause & goto MENU_DIAGNOSTICO

:MENU_AMBIENTE
cls
echo.
echo   %C_TITULO%COMPARTDISK%C_RESET%  %C_CINZA%%COMPARTDISK_VERSION%%C_RESET%
echo   %C_CINZA%Ambiente de Execucao e Capacidades%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo   %C_CINZA%Autoria       %C_RESET%%C_TEXTO%DESENVOLVIDO POR EDSILAS%C_RESET%
echo   %C_CINZA%Motor         %C_RESET%%C_TEXTO%%PS_KIND%%C_RESET%
echo   %C_CINZA%Executavel    %C_RESET%%C_TEXTO%%PS_EXE%%C_RESET%
echo   %C_CINZA%Modulos       %C_RESET%%C_TEXTO%%COMPARTDISK_MODULES%%C_RESET%
echo   %C_CINZA%Sessao        %C_RESET%%C_TEXTO%%COMPARTDISK_SESSION%%C_RESET%
echo   %C_CINZA%Log           %C_RESET%%C_TEXTO%%LOGFILE%%C_RESET%
echo.
echo   %C_CINZA%Componentes   %C_RESET%%C_TEXTO%PowerShell %HAS_PS%    Modulos %HAS_MODULES%    Winget %HAS_WINGET%%C_RESET%   %C_CINZA%1=sim 0=nao%C_RESET%
echo   %C_CINZA%              %C_RESET%%C_TEXTO%WMIC %HAS_WMIC%          PnPUtil %HAS_PNP%    manage-bde %HAS_BDE%%C_RESET%
echo   %C_CINZA%Sem PowerShell, toda funcionalidade permanece acessivel pelas rotinas Batch.%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo    %C_CIANO%[1]%C_RESET%  %C_TEXTO%Detalhar Capacidades via PowerShell%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Reexecutar Deteccao de Ambiente%C_RESET%
echo.
echo    %C_CINZA%[0]%C_RESET%  %C_TEXTO%Voltar%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
choice /c 120 /n /m "  Opcao: "
if errorlevel 3 goto MENU_PRINCIPAL
if errorlevel 2 goto MENU_AMBIENTE_REDETECT
if errorlevel 1 call :MOD_CAPACIDADES
pause & goto MENU_AMBIENTE

:MENU_AMBIENTE_REDETECT
call :LOG_MSG "INFO" "Reexecutando deteccao de ambiente..."
:: Repassa a sentinela: ja estamos elevados, reelevar so produziria um ciclo.
start "" "%COMPARTDISK_SELF%" /elevated
goto FIM

:: ==============================================================================
:: 4. MOTOR DE EXECUCAO
:: ==============================================================================

:RUN_PS
:: Executa um modulo PowerShell. Argumentos vao na variavel PS_ARGS.
:: Retorno: codigo do modulo (0=OK, 1=WARN, 2=ERRO, 3=NAO SUPORTADO)
::          9001 = PowerShell indisponivel | 9002 = modulo ausente
if "%HAS_PS%"=="0" (
    set "PS_RC=9001"
    goto RUN_PS_END
)
if not exist "%COMPARTDISK_MODULES%\%~1" (
    call :LOG_MSG "WARN" "Modulo PowerShell ausente: %~1 - aplicando rotina Batch equivalente."
    set "PS_RC=9002"
    goto RUN_PS_END
)
"%PS_EXE%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%COMPARTDISK_MODULES%\%~1" %PS_ARGS%
set "PS_RC=%errorlevel%"
if "%PS_RC%"=="2" call :LOG_MSG "ERR" "Modulo %~1 retornou erro. Consulte o log detalhado."
if "%PS_RC%"=="3" call :LOG_MSG "WARN" "Recurso nao suportado neste hardware/edicao (%~1)."
:RUN_PS_END
set "PS_ARGS="
:: Codigo 3 e os 9001/9002 significam nao executado ou substituido pelo
:: fallback Batch: contam como pulado, nunca como erro.
if "%PS_RC%"=="0" set /a MOD_OK+=1
if "%PS_RC%"=="1" set /a MOD_WARN+=1
if "%PS_RC%"=="2" set /a MOD_ERR+=1
if "%PS_RC%"=="3" set /a MOD_SKIP+=1
if "%PS_RC%"=="9001" set /a MOD_SKIP+=1
if "%PS_RC%"=="9002" set /a MOD_SKIP+=1
exit /b %PS_RC%

:: ------------------------------------------------------------------------------
:: REPARO GERAL AUTOMATICO
:: ------------------------------------------------------------------------------
:MOD_AUTO_FIX
cls
call :MOD_AUTO_FIX_CORE
echo.
echo   %C_AMARELO%Reinicie o computador para aplicar todas as alteracoes.%C_RESET%
pause & goto MENU_PRINCIPAL

:MOD_AUTO_FIX_CORE
:: Cada etapa e avaliada individualmente. Antes, as sete eram encadeadas sem
:: nenhuma verificacao e a rotina gravava "REPARO AUTOMATICO CONCLUIDO" como
:: [ OK ] mesmo que todas tivessem falhado - o operador lia "concluido" sobre
:: um reparo que nao aconteceu.
::
:: A medicao usa os contadores que :RUN_PS_END ja mantem, que sao alimentados
:: pelo codigo de saida real de cada modulo. Uma etapa desviada para o fallback
:: Batch conta como pulada, nao como concluida: o Launcher nao tem como afirmar
:: que a rotina Batch atingiu o mesmo estado final.
call :LOG_MSG "INFO" "=== INICIANDO ROTINA ONE-CLICK FIX ==="
set "AF_TOTAL=0"
set "AF_OK=0"
set "AF_WARN=0"
set "AF_ERR=0"
set "AF_SKIP=0"

call :AF_ETAPA "Limpeza de temporarios e logs"      MOD_TEMP_LOGS_SILENT
call :AF_ETAPA "Redefinicao da pilha de rede"       MOD_REDE_RESET
call :AF_ETAPA "Redefinicao do Windows Update"      MOD_UPDATE_RESET
call :AF_ETAPA "Fila de impressao"                  MOD_SPOOLER
call :AF_ETAPA "Reinicio do Explorer"               MOD_EXPLORER
call :AF_ETAPA "Verificacao de integridade do sistema" MOD_SFC_DISM
call :AF_ETAPA "Geracao dos relatorios"             MOD_RELATORIO_SILENCIOSO

call :LOG_MSG "INFO" "Etapas: %AF_TOTAL% | concluidas: %AF_OK% | com atencao: %AF_WARN% | puladas: %AF_SKIP% | falhas: %AF_ERR%"
if not "%AF_ERR%"=="0"  goto AF_FIM_ERRO
if not "%AF_WARN%"=="0" goto AF_FIM_WARN
if not "%AF_SKIP%"=="0" goto AF_FIM_WARN
call :LOG_MSG "OK" "=== REPARO AUTOMATICO CONCLUIDO: as %AF_TOTAL% etapas foram concluidas ==="
goto :EOF

:AF_FIM_ERRO
call :LOG_MSG "ERR" "=== REPARO AUTOMATICO INCOMPLETO: %AF_ERR% etapa(s) falharam de %AF_TOTAL% ==="
call :LOG_MSG "INFO" "As etapas concluidas permanecem aplicadas. Consulte o log para a etapa exata."
goto :EOF

:AF_FIM_WARN
call :LOG_MSG "WARN" "=== REPARO AUTOMATICO CONCLUIDO COM RESSALVAS: %AF_WARN% com atencao, %AF_SKIP% pulada(s) de %AF_TOTAL% ==="
goto :EOF

:AF_ETAPA
:: %~1 = nome legivel da etapa   %~2 = rotulo da rotina a executar
:: Compara os contadores antes e depois: e o unico jeito de saber o desfecho de
:: uma etapa que internamente chama varios modulos.
set /a AF_TOTAL+=1
set "AF_E0=%MOD_ERR%"
set "AF_W0=%MOD_WARN%"
set "AF_S0=%MOD_SKIP%"
call :LOG_MSG "INFO" "Etapa %AF_TOTAL%: %~1"
call :%~2
if not "%MOD_ERR%"=="%AF_E0%"  goto AF_ETAPA_ERRO
if not "%MOD_WARN%"=="%AF_W0%" goto AF_ETAPA_WARN
if not "%MOD_SKIP%"=="%AF_S0%" goto AF_ETAPA_SKIP
set /a AF_OK+=1
call :LOG_MSG "OK" "Etapa concluida: %~1"
goto :EOF

:AF_ETAPA_ERRO
set /a AF_ERR+=1
call :LOG_MSG "ERR" "Etapa nao concluida: %~1"
goto :EOF

:AF_ETAPA_WARN
set /a AF_WARN+=1
call :LOG_MSG "WARN" "Etapa concluida com ressalvas: %~1"
goto :EOF

:AF_ETAPA_SKIP
set /a AF_SKIP+=1
call :LOG_MSG "WARN" "Etapa desviada para a rotina Batch ou nao suportada: %~1"
goto :EOF

:: ------------------------------------------------------------------------------
:: WINGET (permanece em Batch: o winget e uma CLI e o Batch a conduz bem)
:: ------------------------------------------------------------------------------
:MOD_WINGET_MENU
cls
call :MOD_WINGET
pause & goto MENU_PRINCIPAL

:MOD_WINGET
if "%HAS_WINGET%"=="0" (
    call :LOG_MSG "ERR" "Winget ausente ou corrompido neste sistema."
    goto :EOF
)
call :LOG_MSG "INFO" "Testando fontes e conectividade com repositorios Winget..."
winget source update >nul 2>&1
if errorlevel 1 call :LOG_MSG "WARN" "Acesso ao repositorio falhou (Offline ou Firewall). Tentando cache local..."
call :LOG_MSG "INFO" "Buscando e aplicando atualizacoes (Isso pode demorar)..."
winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements
if errorlevel 1 (
    call :LOG_MSG "WARN" "Processo finalizado com ressalvas (Aplicativos em uso ou sem rede)."
) else (
    call :LOG_MSG "OK" "Processo de atualizacao Winget concluido."
)
goto :EOF

:: ------------------------------------------------------------------------------
:: REDE
:: ------------------------------------------------------------------------------
:MOD_REDE_RESET
set "PS_ARGS=-Action Reset"
call :RUN_PS "Network.ps1"
if errorlevel 9000 goto FB_REDE_RESET
goto :EOF

:MOD_REDE_HOSTS
set "PS_ARGS=-Action Hosts"
call :RUN_PS "Network.ps1"
if errorlevel 9000 goto FB_REDE_HOSTS
goto :EOF

:MOD_FIREWALL
set "PS_ARGS=-Action Firewall"
call :RUN_PS "Network.ps1"
if errorlevel 9000 goto FB_FIREWALL
goto :EOF

:MOD_REDE_INFO
set "PS_ARGS=-Action Info"
call :RUN_PS "Network.ps1"
if errorlevel 9000 goto FB_REDE_INFO
goto :EOF

:MOD_REDE_TESTE
set "PS_ARGS=-Action Test"
call :RUN_PS "Network.ps1"
if errorlevel 9000 goto FB_REDE_TESTE
goto :EOF

:MOD_REDE_PROXY
set "PS_ARGS=-Action Proxy"
call :RUN_PS "Network.ps1"
if errorlevel 9000 goto FB_REDE_PROXY
goto :EOF

:MOD_REDE_WIFI
set "PS_ARGS=-Action Wifi"
call :RUN_PS "Network.ps1"
if errorlevel 9000 goto FB_REDE_WIFI
goto :EOF

:: ------------------------------------------------------------------------------
:: LIMPEZA E OTIMIZACAO
:: ------------------------------------------------------------------------------
:MOD_TEMP_LOGS
call :LOG_MSG "INFO" "Preparando limpeza profunda do sistema..."
choice /c SN /n /m "Deseja apagar tambem Logs de Eventos e Arquivos de Crash/Dumps (Afeta auditoria)? (S/N): "
if errorlevel 2 goto MOD_TEMP_LOGS_PADRAO
set "PS_ARGS=-Action Logs"
call :RUN_PS "Cleanup.ps1"
if errorlevel 9000 call :FB_LIMPEZA_LOGS
:MOD_TEMP_LOGS_PADRAO
set "PS_ARGS=-Action Deep"
call :RUN_PS "Cleanup.ps1"
if errorlevel 9000 goto FB_LIMPEZA
goto :EOF

:MOD_TEMP_LOGS_SILENT
set "PS_ARGS=-Action Deep -Quiet"
call :RUN_PS "Cleanup.ps1"
if errorlevel 9000 goto FB_LIMPEZA
goto :EOF

:MOD_LIMPEZA_SIMULACAO
set "PS_ARGS=-Action Analyze"
call :RUN_PS "Cleanup.ps1"
if errorlevel 9000 call :LOG_MSG "WARN" "A simulacao de limpeza requer PowerShell. Use a limpeza padrao."
goto :EOF

:MOD_LIMPEZA_NAVEGADORES
set "PS_ARGS=-Action Browsers"
call :RUN_PS "Cleanup.ps1"
if errorlevel 9000 goto FB_LIMPEZA_NAVEGADORES
goto :EOF

:MOD_TELEMETRIA
set "PS_ARGS=-Action Disable"
call :RUN_PS "Telemetry.ps1"
if errorlevel 9000 goto FB_TELEMETRIA
goto :EOF

:MOD_TELEMETRIA_ON
set "PS_ARGS=-Action Enable"
call :RUN_PS "Telemetry.ps1"
if errorlevel 9000 goto FB_TELEMETRIA_ON
goto :EOF

:MOD_PERFORMANCE
set "PS_ARGS=-Action Ultimate"
call :RUN_PS "Performance.ps1"
if errorlevel 9000 goto FB_PERFORMANCE
goto :EOF

:MOD_PERF_BALANCED
set "PS_ARGS=-Action Balanced"
call :RUN_PS "Performance.ps1"
if errorlevel 9000 goto FB_PERF_BALANCED
goto :EOF

:MOD_PERF_ANALISE
set "PS_ARGS=-Action Analyze"
call :RUN_PS "Performance.ps1"
if errorlevel 9000 goto FB_PERF_ANALISE
goto :EOF

:: ------------------------------------------------------------------------------
:: DESBLOAT DO WINDOWS
:: ------------------------------------------------------------------------------
:MOD_DEBLOAT_SIMULAR
set "PS_ARGS=-Action Analyze -Level Moderate"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 goto FB_DEBLOAT
goto :EOF

:MOD_DEBLOAT_SEGURO
echo.
echo   %C_TEXTO%O nivel Seguro remove aplicativos promocionais e pre-instalados de%C_RESET%
echo   %C_TEXTO%fabricante, ajusta servicos sem uso e desliga sugestoes na interface.%C_RESET%
echo   %C_TEXTO%Nada que o Windows precise para funcionar e tocado.%C_RESET%
echo.
echo   %C_TEXTO%Um ponto de restauracao sera criado antes de qualquer alteracao.%C_RESET%
echo.
choice /c SN /n /m "  Continuar? (S/N): "
if errorlevel 2 goto :EOF
set "PS_ARGS=-Action Full -Level Safe"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 goto FB_DEBLOAT
goto :EOF

:MOD_DEBLOAT_MODERADO
echo.
echo   %C_AMARELO%ANTES DE CONTINUAR, LEIA:%C_RESET%
echo.
echo   %C_TEXTO%O nivel Moderado remove tambem os aplicativos Xbox, o player de musica%C_RESET%
echo   %C_TEXTO%e video, o visualizador de Fotos, a Camera, o Email e o Calendario.%C_RESET%
echo.
echo   %C_TEXTO%Se voce usa qualquer um deles, escolha o nivel Seguro.%C_RESET%
echo   %C_TEXTO%Aplicativos removidos so voltam pela Microsoft Store.%C_RESET%
echo.
choice /c SN /n /m "  Continuar mesmo assim? (S/N): "
if errorlevel 2 goto :EOF
set "PS_ARGS=-Action Full -Level Moderate"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 goto FB_DEBLOAT
goto :EOF

:MOD_DEBLOAT_AVANCADO
echo.
echo   %C_AMARELO%ATENCAO - NIVEL AVANCADO%C_RESET%
echo.
echo   %C_TEXTO%Alem de tudo do nivel Moderado, este nivel:%C_RESET%
echo.
echo   %C_TEXTO%  - desativa a indexacao, o que desliga a busca do menu Iniciar;%C_RESET%
echo   %C_TEXTO%  - remove a Ferramenta de Captura e a Calculadora;%C_RESET%
echo   %C_TEXTO%  - aplica /ResetBase no DISM, o que impede desinstalar as%C_RESET%
echo   %C_TEXTO%    atualizacoes do Windows ja aplicadas.%C_RESET%
echo.
echo   %C_TEXTO%Recomendado apenas para quem sabe exatamente o que esta fazendo.%C_RESET%
echo.
choice /c SN /n /m "  Li os avisos e quero continuar? (S/N): "
if errorlevel 2 goto :EOF
set "PS_ARGS=-Action Full -Level Aggressive"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 goto FB_DEBLOAT
goto :EOF

:MOD_DEBLOAT_APPS
set "PS_ARGS=-Action Apps -Level Safe"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 call :LOG_MSG "WARN" "A remocao de aplicativos exige PowerShell. Use Configuracoes / Aplicativos."
goto :EOF

:MOD_DEBLOAT_SERVICOS
set "PS_ARGS=-Action Services -Level Safe"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 goto FB_DEBLOAT_SERVICOS
set "PS_ARGS=-Action Tasks -Level Safe"
call :RUN_PS "Debloat.ps1"
goto :EOF

:MOD_DEBLOAT_PRIVACIDADE
set "PS_ARGS=-Action Privacy -Level Safe"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 goto FB_DEBLOAT_PRIVACIDADE
set "PS_ARGS=-Action Tweaks -Level Safe"
call :RUN_PS "Debloat.ps1"
goto :EOF

:MOD_DEBLOAT_COMPONENTES
echo.
echo   %C_TEXTO%A limpeza do armazenamento de componentes remove versoes superadas de%C_RESET%
echo   %C_TEXTO%arquivos do Windows. Costuma demorar e usar disco intensamente.%C_RESET%
echo.
choice /c SN /n /m "  Continuar? (S/N): "
if errorlevel 2 goto :EOF
set "PS_ARGS=-Action Components -Level Safe"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 goto FB_DEBLOAT_COMPONENTES
goto :EOF

:MOD_DEBLOAT_PONTO
set "PS_ARGS=-Action RestorePoint"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 goto FB_DEBLOAT_PONTO
goto :EOF

:MOD_DEBLOAT_BACKUP
set "PS_ARGS=-Action Backup"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 call :LOG_MSG "WARN" "O registro de estado exige PowerShell."
goto :EOF

:MOD_DEBLOAT_REVERTER_SIMULAR
set "PS_ARGS=-Action Restore -DryRun"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 call :LOG_MSG "WARN" "A reversao exige PowerShell e o manifesto gravado pelo modulo."
goto :EOF

:MOD_DEBLOAT_REVERTER
echo.
echo   %C_TEXTO%Servicos, tarefas e ajustes de registro voltarao ao estado anterior.%C_RESET%
echo   %C_TEXTO%Os aplicativos removidos serao apenas listados para reinstalacao.%C_RESET%
echo.
choice /c SN /n /m "  Confirmar a reversao? (S/N): "
if errorlevel 2 goto :EOF
set "PS_ARGS=-Action Restore"
call :RUN_PS "Debloat.ps1"
if errorlevel 9000 call :LOG_MSG "WARN" "A reversao exige PowerShell e o manifesto gravado pelo modulo."
goto :EOF

:: ------------------------------------------------------------------------------
:: REPARO DO SISTEMA
:: ------------------------------------------------------------------------------
:MOD_SFC_DISM
set "PS_ARGS=-Action Full"
call :RUN_PS "Repair.ps1"
if errorlevel 9000 goto FB_SFC_DISM
goto :EOF

:MOD_CHKDSK
set "PS_ARGS=-Action Chkdsk -Drive C:"
call :RUN_PS "Repair.ps1"
if errorlevel 9000 goto FB_CHKDSK
goto :EOF

:MOD_UPDATE_RESET
set "PS_ARGS=-Action Reset"
call :RUN_PS "Update.ps1"
if errorlevel 9000 goto FB_UPDATE_RESET
goto :EOF

:MOD_UPDATE_STATUS
set "PS_ARGS=-Action Status"
call :RUN_PS "Update.ps1"
if errorlevel 9000 goto FB_UPDATE_STATUS
set "PS_ARGS=-Action History"
call :RUN_PS "Update.ps1"
goto :EOF

:MOD_UPDATE_BUSCAR
set "PS_ARGS=-Action Search"
call :RUN_PS "Update.ps1"
if errorlevel 9000 call :LOG_MSG "WARN" "A busca de atualizacoes requer PowerShell. Abra Configuracoes / Windows Update."
goto :EOF

:MOD_UPDATE_CACHE
set "PS_ARGS=-Action Cache"
call :RUN_PS "Update.ps1"
if errorlevel 9000 goto FB_UPDATE_CACHE
goto :EOF

:MOD_SPOOLER
set "PS_ARGS=-Action Spooler"
call :RUN_PS "Explorer.ps1"
if errorlevel 9000 goto FB_SPOOLER
goto :EOF

:MOD_EXPLORER
set "PS_ARGS=-Action Restart"
call :RUN_PS "Explorer.ps1"
if errorlevel 9000 goto FB_EXPLORER
goto :EOF

:MOD_EXPLORER_CACHE
set "PS_ARGS=-Action ClearCache"
call :RUN_PS "Explorer.ps1"
if errorlevel 9000 goto FB_EXPLORER_CACHE
goto :EOF

:: ------------------------------------------------------------------------------
:: SEGURANCA E CONTAS
:: ------------------------------------------------------------------------------
:MOD_GPO_RESET
echo.
echo   %C_AMARELO%ANTES DE CONTINUAR, LEIA:%C_RESET%
echo.
echo   %C_TEXTO%Esta opcao devolve as diretivas locais aos padroes do Windows.%C_RESET%
echo.
echo   %C_TEXTO%Se hoje voce entra no computador SEM digitar senha, essa entrada%C_RESET%
echo   %C_TEXTO%automatica pode ser desligada. O Windows voltara a pedir a senha da%C_RESET%
echo   %C_TEXTO%sua conta - a mesma de sempre, que talvez voce nunca tenha digitado.%C_RESET%
echo.
echo   %C_TEXTO%Confirme que sabe a senha da sua conta antes de prosseguir.%C_RESET%
echo   %C_TEXTO%Em computador da empresa, fale com a TI: configuracoes obrigatorias%C_RESET%
echo   %C_TEXTO%podem ser removidas.%C_RESET%
echo.
choice /c SN /n /m "  Sei a senha da minha conta e quero continuar? (S/N): "
if errorlevel 2 goto :EOF
set "PS_ARGS=-Action GpoReset"
call :RUN_PS "Security.ps1"
if errorlevel 9000 goto FB_GPO_RESET
goto :EOF

:MOD_SEGURANCA_STATUS
set "PS_ARGS=-Action Status"
call :RUN_PS "Security.ps1"
if errorlevel 9000 goto FB_SEGURANCA_STATUS
goto :EOF

:MOD_DEFENDER
set "PS_ARGS=-Action Update"
call :RUN_PS "Defender.ps1"
if errorlevel 9000 goto FB_DEFENDER
set "PS_ARGS=-Action QuickScan"
call :RUN_PS "Defender.ps1"
goto :EOF

:MOD_DEFENDER_STATUS
set "PS_ARGS=-Action Status"
call :RUN_PS "Defender.ps1"
if errorlevel 9000 goto FB_DEFENDER_STATUS
goto :EOF

:MOD_DEFENDER_FULL
echo   %C_AMARELO%A varredura completa pode levar varias horas e usar CPU intensamente.%C_RESET%
choice /c SN /n /m "Confirmar varredura completa? (S/N): "
if errorlevel 2 goto :EOF
set "PS_ARGS=-Action FullScan"
call :RUN_PS "Defender.ps1"
if errorlevel 9000 call :LOG_MSG "ERR" "PowerShell inativo. Use Seguranca do Windows para a varredura completa."
goto :EOF

:MOD_DEFENDER_EXCL
set "PS_ARGS=-Action Exclusions"
call :RUN_PS "Defender.ps1"
if errorlevel 9000 (
    call :LOG_MSG "WARN" "Exclusoes e historico de ameacas exigem PowerShell. Consulte Seguranca do Windows."
    goto :EOF
)
set "PS_ARGS=-Action History"
call :RUN_PS "Defender.ps1"
goto :EOF

:MOD_USERS
:: A listagem termina aqui. Qualquer alteracao passa a exigir uma escolha
:: deliberada no submenu abaixo. Antes, o campo de troca de senha vinha
:: emendado na listagem, sem que o usuario tivesse pedido isso.
set "PS_ARGS=-Action List"
call :RUN_PS "Users.ps1"
if errorlevel 9000 goto FB_USERS

:MOD_USERS_ESCOLHA
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_TEXTO%A lista acima e apenas informativa. Nada foi alterado ate aqui.%C_RESET%
echo.
echo    %C_CINZA%[1]%C_RESET%  %C_TEXTO%Voltar sem alterar nada%C_RESET%   %C_CINZA%(recomendado)%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Definir uma nova senha para uma conta%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Ativar a conta interna de Administrador%C_RESET%
echo.
echo   %C_AMARELO%As opcoes [2] e [3] alteram a forma de entrar no Windows.%C_RESET%
echo.
choice /c 123 /n /m "  Opcao: "
if errorlevel 3 goto MOD_USERS_ADMIN
if errorlevel 2 goto MOD_USERS_SENHA
goto :EOF

:MOD_USERS_SENHA
echo.
echo   %C_AMARELO%ANTES DE CONTINUAR, LEIA:%C_RESET%
echo.
echo   %C_TEXTO%1. Se voce entra no Windows com um E-MAIL (conta Microsoft), a senha%C_RESET%
echo   %C_TEXTO%   NAO deve ser trocada aqui. Troque em account.microsoft.com.%C_RESET%
echo.
echo   %C_TEXTO%2. Anote a nova senha ANTES de digitar. Ao digita-la, a tela nao%C_RESET%
echo   %C_TEXTO%   mostra nada, nem asteriscos. E o comportamento normal do Windows.%C_RESET%
echo.
echo   %C_TEXTO%3. Se hoje voce entra sem digitar senha, definir uma senha aqui fara%C_RESET%
echo   %C_TEXTO%   o Windows passar a pedi-la em todo login.%C_RESET%
echo.
choice /c SN /n /m "  Li e quero continuar? (S/N): "
if errorlevel 2 goto MOD_USERS_ESCOLHA
echo.
set "TARGET_USER="
set /p "TARGET_USER=  Nome EXATO da conta, como aparece na lista (Enter cancela): "
if not defined TARGET_USER goto MOD_USERS_ESCOLHA
:: Aspa solta na entrada quebra o encadeamento de PS_ARGS na linha de comando do
:: PowerShell. Nome de conta do Windows nunca contem aspas: remove-las e seguro.
set "TARGET_USER=%TARGET_USER:"=%"
if not defined TARGET_USER goto MOD_USERS_ESCOLHA
set "PS_ARGS=-Action SetPassword -User "%TARGET_USER%""
call :RUN_PS "Users.ps1"
:: :FB_USERS_SENHA ja existia completa (net user <conta> *, com verificacao de
:: errorlevel) e nenhuma linha a chamava. Executar a rotina e melhor do que
:: instruir o usuario a digitar o mesmo comando a mao.
if errorlevel 9000 goto FB_USERS_SENHA
goto :EOF

:MOD_USERS_ADMIN
echo.
echo   %C_AMARELO%A conta interna de Administrador nasce SEM SENHA.%C_RESET%
echo.
echo   %C_TEXTO%Ela passara a aparecer na tela de login, e quem tiver acesso fisico ao%C_RESET%
echo   %C_TEXTO%computador podera entrar por ela sem digitar nada.%C_RESET%
echo.
echo   %C_TEXTO%E util para recuperar acesso. Depois de usar, desative-a.%C_RESET%
echo.
choice /c SN /n /m "  Ativar mesmo assim? (S/N): "
if errorlevel 2 goto MOD_USERS_ESCOLHA
set "PS_ARGS=-Action EnableAdmin"
call :RUN_PS "Users.ps1"
if errorlevel 9000 goto FB_USERS_ADMIN
goto :EOF

:MOD_USERS_AUDIT
set "PS_ARGS=-Action Audit"
call :RUN_PS "Users.ps1"
if errorlevel 9000 goto FB_USERS_LIST
goto :EOF

:MOD_TAKEOWN
set "TARGET_PATH="
set /p "TARGET_PATH=Cole o caminho exato do arquivo/pasta (ou Enter para cancelar): "
if not defined TARGET_PATH goto :EOF
:: O Explorer copia caminhos ja entre aspas, e uma aspa solta quebraria o
:: encadeamento de PS_ARGS. Caminho do Windows nunca contem aspas: remove-las
:: e seguro e ainda faz o texto colado do Explorer funcionar direto.
set "TARGET_PATH=%TARGET_PATH:"=%"
if not defined TARGET_PATH goto :EOF
set "PS_ARGS=-Action Takeown -Path "%TARGET_PATH%""
call :RUN_PS "Security.ps1"
if errorlevel 9000 goto FB_TAKEOWN
goto :EOF

:: ------------------------------------------------------------------------------
:: HARDWARE, DISCOS E DRIVERS
:: ------------------------------------------------------------------------------
:MOD_SMART
set "PS_ARGS=-Action Status"
call :RUN_PS "Smart.ps1"
if errorlevel 9000 goto FB_SMART
goto :EOF

:MOD_SMART_DETALHE
set "PS_ARGS=-Action Detail"
call :RUN_PS "Smart.ps1"
if errorlevel 9000 goto FB_SMART
goto :EOF

:MOD_VOLUMES
set "PS_ARGS=-Action Volumes"
call :RUN_PS "Smart.ps1"
if errorlevel 9000 goto FB_VOLUMES
set "PS_ARGS=-Action Shadow"
call :RUN_PS "Smart.ps1"
goto :EOF

:MOD_BATTERY
set "PS_ARGS=-Action Info"
call :RUN_PS "Battery.ps1"
if errorlevel 9000 goto FB_BATTERY
set "PS_ARGS=-Action Report"
call :RUN_PS "Battery.ps1"
goto :EOF

:MOD_BITLOCKER
set "PS_ARGS=-Action Status"
call :RUN_PS "Bitlocker.ps1"
if errorlevel 9000 goto FB_BITLOCKER
goto :EOF

:MOD_DRIVERS
set "PS_ARGS=-Action Backup"
call :RUN_PS "Drivers.ps1"
if errorlevel 9000 goto FB_DRIVERS
goto :EOF

:MOD_DRIVERS_PROBLEMAS
set "PS_ARGS=-Action Problems"
call :RUN_PS "Drivers.ps1"
if errorlevel 9000 goto FB_DRIVERS_PROBLEMAS
set "PS_ARGS=-Action Unsigned"
call :RUN_PS "Drivers.ps1"
goto :EOF

:MOD_DRIVERS_EXPORT
set "PS_ARGS=-Action Export"
call :RUN_PS "Drivers.ps1"
if errorlevel 9000 call :LOG_MSG "WARN" "A exportacao do inventario requer PowerShell."
goto :EOF

:MOD_HARDWARE_FULL
set "PS_ARGS=-Action Full"
call :RUN_PS "Hardware.ps1"
if errorlevel 9000 goto FB_SYSINFO
goto :EOF

:MOD_SYSINFO
set "PS_ARGS=-Action Info"
call :RUN_PS "Hardware.ps1"
if errorlevel 9000 goto FB_SYSINFO
goto :EOF

:: ------------------------------------------------------------------------------
:: DIAGNOSTICO E RELATORIOS
:: ------------------------------------------------------------------------------
:MOD_AUDITORIA_COMPLETA
set "PS_ARGS=-Action Full -Days 7"
call :RUN_PS "Audit.ps1"
if errorlevel 9000 goto FB_AUDITORIA
goto :EOF

:MOD_AUDITORIA_COMPLETA_CLI
:: Mesma auditoria da opcao [8][1], sem abrir o navegador ao final. Em parque de
:: maquinas, /audit abria uma janela em cada estacao - o oposto de desassistido.
set "PS_ARGS=-Action Full -Days 7 -NoOpen"
call :RUN_PS "Audit.ps1"
if errorlevel 9000 goto FB_AUDITORIA
goto :EOF

:MOD_AUDITORIA_RAPIDA
set "PS_ARGS=-Action Quick"
call :RUN_PS "Audit.ps1"
if errorlevel 9000 goto FB_AUDITORIA
goto :EOF

:MOD_EVENTOS_7
set "PS_ARGS=-Action Events -Days 7 -NoReport"
call :RUN_PS "Audit.ps1"
if errorlevel 9000 goto FB_EVENTOS
goto :EOF

:MOD_EVENTOS_30
set "PS_ARGS=-Action Events -Days 30 -NoReport"
call :RUN_PS "Audit.ps1"
if errorlevel 9000 goto FB_EVENTOS
goto :EOF

:MOD_SOFTWARE
set "PS_ARGS=-Action Software -NoReport"
call :RUN_PS "Audit.ps1"
if errorlevel 9000 goto FB_SOFTWARE
goto :EOF

:MOD_LICENCA
set "PS_ARGS=-Action License -NoReport"
call :RUN_PS "Audit.ps1"
if errorlevel 9000 goto FB_LICENCA
goto :EOF

:MOD_RELATORIO
set "PS_ARGS=-Action Consolidate"
call :RUN_PS "Report.ps1"
if errorlevel 9000 goto FB_RELATORIO
goto :EOF

:MOD_RELATORIO_CLI
:: Consolidacao identica a da opcao [8][3], sem abrir o navegador. Mantem a saida
:: em tela, ao contrario de :MOD_RELATORIO_SILENCIOSO, que tambem e -Quiet.
set "PS_ARGS=-Action Consolidate -NoOpen"
call :RUN_PS "Report.ps1"
if errorlevel 9000 goto FB_RELATORIO
goto :EOF

:MOD_RELATORIO_SILENCIOSO
set "PS_ARGS=-Action Consolidate -NoOpen -Quiet"
call :RUN_PS "Report.ps1"
goto :EOF

:MOD_RELATORIO_ABRIR
set "PS_ARGS=-Action Open"
call :RUN_PS "Report.ps1"
if errorlevel 9000 call :LOG_MSG "WARN" "Abra manualmente o arquivo: %LOGFILE%"
goto :EOF

:MOD_CAPACIDADES
if "%HAS_PS%"=="0" (
    call :LOG_MSG "WARN" "PowerShell indisponivel: capacidades detalhadas nao podem ser consultadas."
    goto :EOF
)
"%PS_EXE%" -NoProfile -NoLogo -ExecutionPolicy Bypass -Command ". '%COMPARTDISK_MODULES%\Core.ps1'; $c = Get-CompartDiskCapabilities; foreach ($k in ($c.Keys | Sort-Object)) { '{0,-14}: {1}' -f $k, $c[$k] }"
goto :EOF

:: ==============================================================================
:: 5. FALLBACKS BATCH (usados quando o PowerShell esta ausente ou bloqueado)
::    Implementacoes Batch nativas, equivalentes funcionais de cada modulo.
:: ==============================================================================

:FB_REDE_RESET
call :LOG_MSG "INFO" "[Batch] Resetando sockets e caches de rede..."
ipconfig /release >nul 2>&1
ipconfig /flushdns >nul 2>&1
ipconfig /renew >nul 2>&1
netsh winsock reset >nul 2>&1
netsh int ip reset >nul 2>&1
netsh int ipv6 reset >nul 2>&1
netsh winhttp reset proxy >nul 2>&1
arp -d * >nul 2>&1
call :LOG_MSG "OK" "Rede TCP/IP e DNS redefinidos."
goto :EOF

:FB_REDE_HOSTS
echo # Arquivo Hosts Padrao > "%windir%\System32\drivers\etc\hosts"
echo 127.0.0.1 localhost >> "%windir%\System32\drivers\etc\hosts"
echo ::1 localhost >> "%windir%\System32\drivers\etc\hosts"
ipconfig /flushdns >nul 2>&1
call :LOG_MSG "OK" "Arquivo Hosts restaurado para o padrao MSFT."
goto :EOF

:FB_FIREWALL
netsh advfirewall export "%LOGDIR%Firewall_Backup.wfw" >nul 2>&1
netsh advfirewall reset >nul 2>&1
netsh advfirewall set allprofiles state on >nul 2>&1
call :LOG_MSG "OK" "Regras do Firewall restauradas."
goto :EOF

:FB_REDE_INFO
echo.
ipconfig /all
echo.
route print -4
goto :EOF

:FB_REDE_TESTE
echo.
ping -n 4 8.8.8.8
echo.
nslookup www.microsoft.com
goto :EOF

:FB_REDE_PROXY
netsh winhttp show proxy
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer 2>nul
goto :EOF

:FB_REDE_WIFI
netsh wlan show interfaces
netsh wlan show profiles
goto :EOF

:FB_LIMPEZA
:: Preserva os arquivos da propria ferramenta em %TEMP%, como Cleanup.ps1 ja faz
:: com -ExcludePatterns: na execucao remota os modulos vivem em
:: %TEMP%\COMPARTDISK_<id>, o trace fica em %TEMP%\COMPARTDISK_Bootstrap.log e
:: LOGDIR pode ter caido para %TEMP%, com o log da sessao dentro.
for /f "delims=" %%T in ('dir /b /a-d "%TEMP%" 2^>nul ^| findstr /v /i /b "COMPARTDISK_ Relatorio_Manutencao"') do del /q /f "%TEMP%\%%T" >nul 2>&1
for /f "delims=" %%T in ('dir /b /ad "%TEMP%" 2^>nul ^| findstr /v /i /b "COMPARTDISK_"') do rd /s /q "%TEMP%\%%T" >nul 2>&1
del /q /f /s "%SystemRoot%\Temp\*" >nul 2>&1
rd /s /q "%SystemDrive%\$Recycle.bin" >nul 2>&1
del /q /f /s "%SystemRoot%\Prefetch\*" >nul 2>&1
del /q /f /s "%SystemRoot%\SoftwareDistribution\Download\*" >nul 2>&1
rd /s /q "%SystemRoot%\SoftwareDistribution\DeliveryOptimization" >nul 2>&1
:: Limpeza avancada Chromium (Cobre multiplos caches em TODOS os perfis)
for %%N in ("Google\Chrome", "Microsoft\Edge") do (
    if exist "%LocalAppData%\%%~N\User Data" (
        for /d %%D in ("%LocalAppData%\%%~N\User Data\*") do (
            :: Lista identica a de Cleanup.ps1:62. "Network" NAO entra: guarda Cookies e
            :: TransportSecurity, nao cache - apaga-la desconecta o usuario de todos os
            :: sites. :FB_LIMPEZA_NAVEGADORES, a rotina dedicada, ja a excluia.
            for %%C in ("Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "Service Worker\CacheStorage", "Service Worker\ScriptCache") do (
                if exist "%%D\%%~C" rd /s /q "%%D\%%~C" >nul 2>&1
            )
        )
    )
)
ipconfig /flushdns >nul 2>&1
call :LOG_MSG "OK" "Arquivos temporarios e caches de navegadores limpos."
goto :EOF

:FB_LIMPEZA_NAVEGADORES
for %%N in ("Google\Chrome", "Microsoft\Edge", "BraveSoftware\Brave-Browser") do (
    if exist "%LocalAppData%\%%~N\User Data" (
        for /d %%D in ("%LocalAppData%\%%~N\User Data\*") do (
            for %%C in ("Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "Service Worker\CacheStorage", "Service Worker\ScriptCache") do (
                if exist "%%D\%%~C" rd /s /q "%%D\%%~C" >nul 2>&1
            )
        )
    )
)
call :LOG_MSG "OK" "Caches de navegadores limpos."
goto :EOF

:FB_LIMPEZA_LOGS
for /F "tokens=*" %%G in ('wevtutil.exe el') DO (wevtutil.exe cl "%%G" >nul 2>&1)
del /q /f /s "%SystemRoot%\Logs\CBS\*" >nul 2>&1
del /q /f /s "%SystemRoot%\Logs\DISM\*" >nul 2>&1
del /q /f /s "%SystemRoot%\Minidump\*" >nul 2>&1
del /q /f "%SystemRoot%\Memory.dmp" >nul 2>&1
rd /s /q "C:\ProgramData\Microsoft\Windows\WER\ReportQueue" >nul 2>&1
call :LOG_MSG "OK" "Dumps e Event Logs apagados."
goto :EOF

:FB_TELEMETRIA
sc stop "DiagTrack" >nul 2>&1
sc config "DiagTrack" start= disabled >nul 2>&1
sc stop "dmwappushservice" >nul 2>&1
sc config "dmwappushservice" start= disabled >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f >nul 2>&1
call :LOG_MSG "OK" "Telemetria da Microsoft desativada."
goto :EOF

:FB_TELEMETRIA_ON
sc config "DiagTrack" start= auto >nul 2>&1
sc start "DiagTrack" >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 1 /f >nul 2>&1
call :LOG_MSG "OK" "Telemetria restaurada ao padrao."
goto :EOF

:: --- Desbloat em modo degradado -------------------------------------------
:: Cobre o que sc.exe, schtasks.exe, reg.exe e dism.exe alcancam. A remocao de
:: aplicativos da loja depende do subsistema Appx e nao tem equivalente Batch.
:FB_DEBLOAT
call :LOG_MSG "WARN" "[Batch] Desbloat reduzido: sem PowerShell nao ha catalogo, simulacao nem manifesto de reversao."
call :FB_DEBLOAT_SERVICOS
call :FB_DEBLOAT_PRIVACIDADE
call :LOG_MSG "INFO" "Remocao de aplicativos indisponivel em Batch. Use Configuracoes / Aplicativos / Aplicativos instalados."
goto :EOF

:FB_DEBLOAT_SERVICOS
call :LOG_MSG "INFO" "[Batch] Ajustando servicos e tarefas sem uso (subconjunto seguro)..."
for %%S in (MapsBroker RetailDemo WMPNetworkSvc Fax RemoteRegistry) do (
    sc config %%S start= disabled >nul 2>&1
    sc stop %%S >nul 2>&1
)
sc config PrintNotify start= demand >nul 2>&1
call :LOG_MSG "OK" "Servicos sem uso desabilitados."
for %%T in (
    "\Microsoft\Windows\Application Experience\StartupAppTask"
    "\Microsoft\Windows\Application Experience\PcaPatchDbTask"
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
    "\Microsoft\Windows\CloudExperienceHost\CreateObjectTask"
    "\Microsoft\Windows\Maps\MapsToastTask"
    "\Microsoft\Windows\Maps\MapsUpdateTask"
    "\Microsoft\Windows\Retail Demo\CleanupOfflineContent"
    "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
) do (
    schtasks /Change /TN %%T /Disable >nul 2>&1
)
call :LOG_MSG "OK" "Tarefas agendadas sem uso desabilitadas."
goto :EOF

:FB_DEBLOAT_PRIVACIDADE
call :LOG_MSG "INFO" "[Batch] Aplicando ajustes de privacidade e interface..."
set "CDM=HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
for %%V in (SilentInstalledAppsEnabled PreInstalledAppsEnabled OemPreInstalledAppsEnabled SystemPaneSuggestionsEnabled SoftLandingEnabled SubscribedContent-338388Enabled SubscribedContent-338389Enabled SubscribedContent-353694Enabled SubscribedContent-353696Enabled) do (
    reg add "%CDM%" /v %%V /t REG_DWORD /d 0 /f >nul 2>&1
)
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement" /v ScoobeSystemSettingEnabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\InputPersonalization" /v RestrictImplicitTextCollection /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\InputPersonalization" /v RestrictImplicitInkCollection /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v BingSearchEnabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v CortanaConsent /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v HideFileExt /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v LaunchTo /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarDa /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" /v EnableFeeds /t REG_DWORD /d 0 /f >nul 2>&1
call :LOG_MSG "OK" "Sugestoes, busca web no Iniciar e itens opcionais da barra de tarefas desativados."
call :LOG_MSG "INFO" "Reinicie o Explorer (menu [5][4]) para ver as mudancas de interface."
goto :EOF

:FB_DEBLOAT_COMPONENTES
call :LOG_MSG "INFO" "[Batch] Compactando o armazenamento de componentes. Pode demorar..."
dism /online /cleanup-image /startcomponentcleanup
if errorlevel 1 (
    call :LOG_MSG "WARN" "A limpeza de componentes retornou erro. Verifique se ha reinicio pendente."
) else (
    call :LOG_MSG "OK" "Armazenamento de componentes compactado."
)
goto :EOF

:FB_DEBLOAT_PONTO
if "%HAS_WMIC%"=="0" (
    call :LOG_MSG "ERR" "WMIC ausente. Crie o ponto por: Painel de Controle / Recuperacao / Configurar Restauracao do Sistema."
    goto :EOF
)
call :LOG_MSG "INFO" "[Batch] Criando ponto de restauracao via WMI..."
wmic.exe /Namespace:\\root\default Path SystemRestore Call CreateRestorePoint "COMPARTDISK - antes do Debloat", 12, 100 >nul 2>&1
if errorlevel 1 (
    call :LOG_MSG "WARN" "Nao foi possivel criar o ponto. A Protecao do Sistema pode estar desligada."
) else (
    call :LOG_MSG "OK" "Ponto de restauracao criado."
)
goto :EOF

:FB_PERFORMANCE
set "TARGET_GUID="

:: 1. Tenta ver se o GUID original ja esta nativamente visivel
powercfg -l | findstr "e9a42b02-d5df-448d-aa00-03f14749eb61" >nul
if not errorlevel 1 (
    set "TARGET_GUID=e9a42b02-d5df-448d-aa00-03f14749eb61"
) else (
    :: 2. Duplica o modelo oculto e captura o novo GUID gerado
    :: O "delims=:" funciona perfeitamente para capturar apos "GUID de Esquema de Energia:" (PT-BR) ou "Power Scheme GUID:" (EN-US)
    for /f "tokens=2 delims=:" %%A in ('powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2^>nul') do (
        for /f "tokens=1" %%B in ("%%A") do set "TARGET_GUID=%%B"
    )
)

:: 3. Se falhou ao duplicar (Notebooks Modern Standby), cai para o plano de "Alto Desempenho" padrao
if not defined TARGET_GUID (
    call :LOG_MSG "WARN" "[Batch] Desempenho Maximo nao suportado. Aplicando Alto Desempenho nativo."
    set "TARGET_GUID=8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
)

:: 4. Ativa o plano capturado
powercfg -setactive %TARGET_GUID% >nul 2>&1
if errorlevel 1 (
    call :LOG_MSG "WARN" "Falha ao aplicar esquema de energia Maximo/Alto."
) else (
    call :LOG_MSG "OK" "Plano de energia de Desempenho ativado com sucesso."
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f >nul 2>&1
)
goto :EOF

:FB_PERF_BALANCED
set "TARGET_GUID=381b4222-f694-41f0-9685-ff5bb260df2e"

:: 1. Confirma se o plano Equilibrado esta disponivel neste sistema.
powercfg -l | findstr /i "381b4222-f694-41f0-9685-ff5bb260df2e" >nul
if errorlevel 1 (
    call :LOG_MSG "WARN" "[Batch] Plano Equilibrado nao esta disponivel neste dispositivo."
    goto :EOF
)

:: 2. Ativa o plano Equilibrado.
powercfg -setactive %TARGET_GUID% >nul 2>&1
if errorlevel 1 (
    call :LOG_MSG "WARN" "[Batch] Falha ao restaurar o plano de energia Equilibrado."
    goto :EOF
)

:: 3. Valida o esquema efetivamente ativo.
powercfg /getactivescheme | findstr /i "%TARGET_GUID%" >nul
if errorlevel 1 (
    call :LOG_MSG "WARN" "[Batch] O Windows nao confirmou o plano Equilibrado como ativo."
    goto :EOF
)

:: 4. Restaura os efeitos visuais ao controle automatico do Windows,
:: alinhando o fallback ao comportamento do Performance.ps1.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 0 /f >nul 2>&1
call :LOG_MSG "OK" "[Batch] Plano de energia Equilibrado restaurado com sucesso."
goto :EOF

:FB_PERF_ANALISE
echo.
call :LOG_MSG "INFO" "[Batch] Executando analise reduzida de desempenho."
powercfg /getactivescheme
echo.
echo --- PROCESSOS POR MEMORIA ---
wmic process get Name,WorkingSetSize /format:table 2>nul
echo.
echo --- INICIALIZACAO ---
wmic startup get Caption,Command,User /format:table 2>nul
echo.
echo --- MEMORIA ---
wmic OS get TotalVisibleMemorySize,FreePhysicalMemory /value 2>nul
echo.
echo --- SERVICOS EM EXECUCAO ---
sc query type= service state= active 2>nul
call :LOG_MSG "OK" "[Batch] Analise reduzida de desempenho concluida."
goto :EOF

:FB_SFC_DISM
call :LOG_MSG "INFO" "[Batch] Iniciando System File Checker (SFC)..."
sfc /scannow
call :LOG_MSG "INFO" "Iniciando Reparo de Imagem (DISM)..."
dism /online /cleanup-image /restorehealth
call :LOG_MSG "OK" "Rotinas SFC e DISM finalizadas."
goto :EOF

:FB_CHKDSK
call :LOG_MSG "INFO" "Injetando pipes de idioma para CHKDSK..."
(echo Y & echo S) | chkdsk C: /f /r >nul 2>&1
call :LOG_MSG "OK" "Verificacao de disco agendada nativamente para o proximo boot."
goto :EOF

:FB_UPDATE_RESET
call :LOG_MSG "INFO" "[Batch] Parando servicos e recriando repositorios do Windows Update..."
net stop wuauserv >nul 2>&1
if errorlevel 1 call :LOG_MSG "WARN" "Servico wuauserv nao parou graciosamente."
net stop cryptSvc >nul 2>&1
net stop bits >nul 2>&1

:: Tratamento rigoroso SoftwareDistribution
:: O .old de uma execucao anterior guarda o estado real anterior a ferramenta.
:: Apaga-lo fazia com que a segunda passada preservasse apenas a pasta ja vazia -
:: e a propria ferramenta recomenda repetir o reset quando algo fica bloqueado.
set "FB_SD_DEST=SoftwareDistribution.old"
if exist "%SystemRoot%\SoftwareDistribution.old" set "FB_SD_DEST=SoftwareDistribution.old_%COMPARTDISK_SESSION%"
if exist "%SystemRoot%\SoftwareDistribution" (
    ren "%SystemRoot%\SoftwareDistribution" "%FB_SD_DEST%" >nul 2>&1
    if exist "%SystemRoot%\SoftwareDistribution" (
        call :LOG_MSG "WARN" "SoftwareDistribution esta bloqueada por processo ativo."
    ) else (
        call :LOG_MSG "OK" "Pasta SoftwareDistribution redefinida."
    )
)

:: Tratamento rigoroso Catroot2
if exist "%SystemRoot%\System32\catroot2.old" rd /s /q "%SystemRoot%\System32\catroot2.old" >nul 2>&1
if exist "%SystemRoot%\System32\catroot2" (
    ren "%SystemRoot%\System32\catroot2" "catroot2.old" >nul 2>&1
    if exist "%SystemRoot%\System32\catroot2" (
        call :LOG_MSG "WARN" "Catroot2 bloqueada (CryptSvc ativo?)."
    ) else (
        call :LOG_MSG "OK" "Pasta Catroot2 redefinida."
    )
)

net start wuauserv >nul 2>&1
net start cryptSvc >nul 2>&1
net start bits >nul 2>&1
goto :EOF

:FB_UPDATE_STATUS
sc query wuauserv
sc query bits
sc query cryptsvc
goto :EOF

:FB_UPDATE_CACHE
net stop wuauserv >nul 2>&1
net stop bits >nul 2>&1
del /q /f /s "%SystemRoot%\SoftwareDistribution\Download\*" >nul 2>&1
net start wuauserv >nul 2>&1
net start bits >nul 2>&1
call :LOG_MSG "OK" "Cache de downloads do Windows Update limpo."
goto :EOF

:FB_SPOOLER
net stop spooler >nul 2>&1
del /Q /F /S "%systemroot%\System32\Spool\Printers\*.*" >nul 2>&1
net start spooler >nul 2>&1
call :LOG_MSG "OK" "Fila de impressao limpa (Spooler resetado)."
goto :EOF

:FB_EXPLORER
taskkill /f /im explorer.exe >nul 2>&1
timeout /t 2 /nobreak >nul
start explorer.exe
call :LOG_MSG "OK" "Interface do Windows reiniciada."
goto :EOF

:FB_EXPLORER_CACHE
taskkill /f /im explorer.exe >nul 2>&1
del /q /f /a "%LocalAppData%\Microsoft\Windows\Explorer\thumbcache_*.db" >nul 2>&1
del /q /f /a "%LocalAppData%\Microsoft\Windows\Explorer\iconcache_*.db" >nul 2>&1
del /q /f /a "%LocalAppData%\IconCache.db" >nul 2>&1
timeout /t 2 /nobreak >nul
start explorer.exe
call :LOG_MSG "OK" "Cache de icones e miniaturas reconstruido."
goto :EOF

:FB_GPO_RESET
rd /s /q "%windir%\System32\GroupPolicy" >nul 2>&1
rd /s /q "%windir%\System32\GroupPolicyUsers" >nul 2>&1
gpupdate /force >nul 2>&1
call :LOG_MSG "OK" "Diretivas de grupo (GPO) locais resetadas."
goto :EOF

:FB_SEGURANCA_STATUS
echo.
echo Firewall:
netsh advfirewall show allprofiles state
echo.
echo UAC (EnableLUA):
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA 2>nul
echo.
echo BitLocker:
manage-bde -status 2>nul
goto :EOF

:FB_DEFENDER
call :LOG_MSG "ERR" "PowerShell inativo. Nao e possivel interagir com o Defender via CLI."
if exist "%ProgramFiles%\Windows Defender\MpCmdRun.exe" (
    call :LOG_MSG "INFO" "Tentando via MpCmdRun.exe..."
    "%ProgramFiles%\Windows Defender\MpCmdRun.exe" -SignatureUpdate
    "%ProgramFiles%\Windows Defender\MpCmdRun.exe" -Scan -ScanType 1
    call :LOG_MSG "OK" "Atualizacao e varredura rapida solicitadas via MpCmdRun."
)
goto :EOF

:FB_DEFENDER_STATUS
sc query WinDefend
if "%HAS_WMIC%"=="1" wmic /namespace:\\root\SecurityCenter2 path AntiVirusProduct get displayName,productState 2>nul
goto :EOF

:FB_USERS_LIST
:: Somente leitura. Usada pela auditoria de contas, que jamais deve oferecer
:: alteracao como efeito colateral da consulta.
echo   %C_CINZA%Contas locais do sistema%C_RESET%
if "%HAS_WMIC%"=="1" (
    wmic useraccount where "LocalAccount=True" get name,disabled 2>nul
) else (
    net user
)
goto :EOF

:FB_USERS
:: Espelha a UX ja adotada no caminho PowerShell (:MOD_USERS_ESCOLHA): a listagem
:: termina aqui, e qualquer alteracao passa a exigir escolha deliberada. Antes, o
:: fallback emendava a REMOCAO de senha na listagem e encadeava a ativacao do
:: Administrador embutido - mais destrutivo que o caminho principal.
call :FB_USERS_LIST
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_TEXTO%A lista acima e apenas informativa. Nada foi alterado ate aqui.%C_RESET%
echo.
echo    %C_CINZA%[1]%C_RESET%  %C_TEXTO%Voltar sem alterar nada%C_RESET%   %C_CINZA%(recomendado)%C_RESET%
echo    %C_CIANO%[2]%C_RESET%  %C_TEXTO%Definir uma nova senha para uma conta%C_RESET%
echo    %C_CIANO%[3]%C_RESET%  %C_TEXTO%Ativar a conta interna de Administrador%C_RESET%
echo.
echo   %C_AMARELO%As opcoes [2] e [3] alteram a forma de entrar no Windows.%C_RESET%
echo.
choice /c 123 /n /m "  Opcao: "
if errorlevel 3 goto FB_USERS_ADMIN_CONFIRMAR
if errorlevel 2 goto FB_USERS_SENHA
goto :EOF

:FB_USERS_SENHA
echo.
echo   %C_TEXTO%O Windows pedira a nova senha em seguida. Ela nao aparece na tela%C_RESET%
echo   %C_TEXTO%enquanto voce digita - e o comportamento normal.%C_RESET%
echo.
echo   %C_TEXTO%Anote a senha ANTES de digitar. Se voce entra no Windows com um%C_RESET%
echo   %C_TEXTO%E-MAIL (conta Microsoft), NAO troque a senha aqui.%C_RESET%
echo.
set "TARGET_USER="
set /p "TARGET_USER=  Nome EXATO da conta, como aparece na lista (Enter cancela): "
if not defined TARGET_USER goto :EOF
set "TARGET_USER=%TARGET_USER:"=%"
if not defined TARGET_USER goto :EOF
net user "%TARGET_USER%" *
if errorlevel 1 (
    call :LOG_MSG "ERR" "Falha ao definir a senha. Verifique se o nome esta correto."
) else (
    call :LOG_MSG "OK" "Senha da conta %TARGET_USER% redefinida."
)
goto :EOF

:FB_USERS_ADMIN_CONFIRMAR
echo.
echo   %C_AMARELO%A conta interna de Administrador nasce SEM SENHA.%C_RESET%
echo.
echo   %C_TEXTO%Ela passara a aparecer na tela de login, e quem tiver acesso fisico ao%C_RESET%
echo   %C_TEXTO%computador podera entrar por ela sem digitar nada.%C_RESET%
echo.
echo   %C_TEXTO%E util para recuperar acesso. Depois de usar, desative-a.%C_RESET%
echo.
choice /c SN /n /m "  Ativar mesmo assim? (S/N): "
if errorlevel 2 goto :EOF
goto FB_USERS_ADMIN

:FB_USERS_ADMIN
net user Administrador /active:yes >nul 2>&1
net user Administrator /active:yes >nul 2>&1
call :LOG_MSG "OK" "Conta Administrador padrao ativada."
goto :EOF

:FB_TAKEOWN
takeown /f "%TARGET_PATH%" /r /d y >nul 2>&1
if errorlevel 1 (
    call :LOG_MSG "ERR" "Falha no Takeown (Erro ao assumir propriedade)."
    goto :EOF
)
icacls "%TARGET_PATH%" /grant *S-1-5-32-544:F /t >nul 2>&1
if errorlevel 1 (
    call :LOG_MSG "ERR" "Falha no Icacls (Erro ao gravar permissoes no ACL)."
) else (
    call :LOG_MSG "OK" "Controle Administrativo (SID-544) concedido com sucesso."
)
goto :EOF

:FB_SMART
call :LOG_MSG "INFO" "[Batch] Lendo metricas de hardware dos discos fisicos..."
if "%HAS_WMIC%"=="1" (
    wmic diskdrive get model,size,status 2>nul
) else (
    call :LOG_MSG "ERR" "Ferramentas necessarias (WMI/PS) inoperantes."
)
call :LOG_MSG "INFO" "Nota: Status 'OK' indica saude basica do WMI, nao diagnostico SMART profundo."
goto :EOF

:FB_VOLUMES
if "%HAS_WMIC%"=="1" (
    wmic logicaldisk where "DriveType=3" get DeviceID,VolumeName,FileSystem,Size,FreeSpace 2>nul
) else (
    fsutil volume diskfree C:
)
goto :EOF

:FB_BATTERY
set "BATTERY_LOG=%LOGDIR%Relatorio_Bateria.html"
powercfg /batteryreport /output "%BATTERY_LOG%" >nul 2>&1
if errorlevel 1 (
    call :LOG_MSG "ERR" "Falha ao gravar relatorio html (sem bateria ou acesso negado)."
) else (
    call :LOG_MSG "OK" "Relatorio gerado!"
    start "" "%BATTERY_LOG%"
)
goto :EOF

:FB_BITLOCKER
call :LOG_MSG "INFO" "[Batch] Mapeando criptografia de volumes..."
if "%HAS_BDE%"=="1" (
    manage-bde -status 2>nul
) else (
    call :LOG_MSG "ERR" "Modulo manage-bde ausente."
)
goto :EOF

:FB_DRIVERS
if "%HAS_PNP%"=="0" (
    call :LOG_MSG "ERR" "PnPUtil nao localizado no Windows."
    goto :EOF
)
if not exist "C:\Backup_Drivers" mkdir "C:\Backup_Drivers"
call :LOG_MSG "INFO" "Exportando drivers locais..."
pnputil /export-driver * "C:\Backup_Drivers" >nul 2>&1
if errorlevel 1 (
    call :LOG_MSG "ERR" "Exportacao retornou erro (Consulte permissao de disco)."
) else (
    call :LOG_MSG "OK" "Drivers extraidos para C:\Backup_Drivers."
)
goto :EOF

:FB_DRIVERS_PROBLEMAS
if "%HAS_WMIC%"=="1" (
    wmic path Win32_PnPEntity where "ConfigManagerErrorCode <> 0" get Name,ConfigManagerErrorCode 2>nul
) else (
    call :LOG_MSG "ERR" "WMIC indisponivel para listar dispositivos com problema."
)
goto :EOF

:FB_SYSINFO
call :LOG_MSG "INFO" "[Batch] Coletando auditoria da placa-mae e sistema..."
if "%HAS_WMIC%"=="1" (
    wmic os get Caption,Version,BuildNumber,OSArchitecture /format:list 2>nul
    wmic cpu get Name,NumberOfCores,NumberOfLogicalProcessors /format:list 2>nul
    wmic baseboard get Manufacturer,Product /format:list 2>nul
    wmic computersystem get Manufacturer,Model,TotalPhysicalMemory /format:list 2>nul
    wmic bios get Manufacturer,SMBIOSBIOSVersion,SerialNumber /format:list 2>nul
    goto :EOF
)
systeminfo | findstr /C:"Nome do sistema" /C:"OS Name" /C:"Versao" /C:"OS Version" /C:"Fabricante" /C:"System Manufacturer"
goto :EOF

:FB_AUDITORIA
call :LOG_MSG "WARN" "[Batch] Auditoria completa reduzida (PowerShell indisponivel)."
call :FB_SYSINFO
call :FB_SMART
call :FB_VOLUMES
call :FB_SEGURANCA_STATUS
call :FB_UPDATE_STATUS
call :LOG_MSG "INFO" "Gerando relatorio texto via systeminfo..."
systeminfo > "%LOGDIR%Auditoria_Sistema.txt" 2>nul
if exist "%LOGDIR%Auditoria_Sistema.txt" call :LOG_MSG "OK" "Relatorio salvo em %LOGDIR%Auditoria_Sistema.txt"
goto :EOF

:FB_EVENTOS
wevtutil qe System /c:30 /rd:true /f:text /q:"*[System[(Level=1 or Level=2)]]" 2>nul
goto :EOF

:FB_SOFTWARE
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" /s /v DisplayName 2>nul | findstr /i "DisplayName"
goto :EOF

:FB_LICENCA
cscript //nologo "%windir%\System32\slmgr.vbs" /dli 2>nul
goto :EOF

:FB_RELATORIO
call :LOG_MSG "WARN" "[Batch] Geracao de relatorios HTML/JSON requer PowerShell."
call :LOG_MSG "INFO" "O log consolidado em texto permanece disponivel."
echo.
echo   Relatorio de texto: %LOGFILE%
goto :EOF

:: ==============================================================================
:: 6. MOTOR CENTRAL DE LOGS, DIAGNOSTICO E SAIDA
:: ==============================================================================

:TRACE
:: Escritor de trace minimo e sem dependencias. Usado desde a primeira linha do
:: bootstrap, inclusive antes de LOGFILE existir. Nunca deve falhar nem abortar.
setlocal EnableExtensions DisableDelayedExpansion
set "TRC=%~1"
if not defined TRC set "TRC=(sem mensagem)"
:: Mesma higienizacao de :LOG_MSG. O trace recebe LOGDIR, que vem de %~dp0 e pode
:: conter "&": fora de aspas, %~1 com "&" parte a linha em dois comandos e trunca
:: justamente o diagnostico de partida.
set "TRC=%TRC:|=/%"
set "TRC=%TRC:&=+%"
set "TRC=%TRC:<=(%"
set "TRC=%TRC:>=)%"
>> "%TRACEFILE%" echo [%DATE% %TIME%] %TRC%
endlocal
exit /b 0

:TESTAR_ESCRITA
:: %~1 = diretorio candidato. Retorna 0 se realmente aceitar gravacao.
if not exist "%~1" mkdir "%~1" >nul 2>&1
> "%~1compartdisk_write_test.tmp" echo teste 2>nul
if not exist "%~1compartdisk_write_test.tmp" exit /b 1
del "%~1compartdisk_write_test.tmp" >nul 2>&1
exit /b 0

:LOG_MSG
:: %~1 = Nivel (INFO, OK, WARN, ERR)   %~2 = Mensagem
:: 
:: A mensagem e HIGIENIZADA antes de ser ecoada. Motivo: em "echo ... %MSG%" a
:: expansao percentual acontece ANTES do reconhecimento de operadores, entao um
:: "|" vindo do conteudo da variavel vira um pipe real. O efeito e que a linha
:: de log e desviada para um comando inexistente e o arquivo fica vazio.
:: DisableDelayedExpansion protege contra "!", mas nao contra "|", "&", "<" e ">".
setlocal EnableExtensions DisableDelayedExpansion
set "LVL=%~1"
set "MSG=%~2"
if not defined MSG set "MSG=(sem mensagem)"
set "MSG=%MSG:|=/%"
set "MSG=%MSG:&=+%"
set "MSG=%MSG:<=(%"
set "MSG=%MSG:>=)%"

:: Marcador de largura fixa: as mensagens ficam alinhadas em coluna, e o
:: formato reproduz o dos relatorios. O arquivo de log mantem o formato
:: original, para nao quebrar leitura de registros anteriores.
set "COLOR=%C_TEXTO%"
set "TAG=[INFO]"
if "%LVL%"=="OK" (set "COLOR=%C_VERDE%" & set "TAG=[ OK ]")
if "%LVL%"=="WARN" (set "COLOR=%C_AMARELO%" & set "TAG=[WARN]")
if "%LVL%"=="ERR" (set "COLOR=%C_VERMELHO%" & set "TAG=[ERRO]")
if "%LVL%"=="INFO" (set "COLOR=%C_CINZA%" & set "TAG=[INFO]")

echo(  %COLOR%%TAG%%C_RESET% %C_TEXTO%%MSG%%C_RESET%
if defined LOGFILE >> "%LOGFILE%" echo [%DATE% %TIME%] [%LVL%] [Launcher] %MSG%
endlocal
goto :EOF

:SAIR
if defined CLI_MODE goto SAIR_CLI
cls
call :LOG_MSG "INFO" "SESSAO ENCERRADA PELO USUARIO."
echo.
echo.
echo   %C_TITULO%COMPARTDISK%C_RESET%  %C_CINZA%%COMPARTDISK_VERSION%%C_RESET%
echo.
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo.
echo   %C_VERDE%Sessao Finalizada%C_RESET%
echo.
echo   %C_CINZA%Log Consolidado%C_RESET%
echo   %C_TEXTO%%LOGFILE%%C_RESET%
echo.
if "%HAS_PS%"=="1" (
    echo   %C_CINZA%Relatorios da Sessao ^(TXT, CSV, JSON, HTML^)%C_RESET%
    echo   %C_TEXTO%%LOGDIR%COMPARTDISK_Relatorios\%COMPARTDISK_SESSION%%C_RESET%
    echo.
)
echo %C_CINZA%  --------------------------------------------------------------------------%C_RESET%
echo   %C_CINZA%DESENVOLVIDO POR EDSILAS%C_RESET%
echo.
pause >nul
goto FIM

:RESUMO_SESSAO
:: Consolida os desfechos ja devolvidos pelos modulos. Nao reinterpreta
:: resultado: apenas soma o que cada modulo reportou.
set /a MOD_TOTAL=MOD_OK+MOD_WARN+MOD_ERR+MOD_SKIP
if "%MOD_TOTAL%"=="0" goto :EOF
call :LOG_MSG "INFO" "RESUMO DA SESSAO - modulos executados: %MOD_TOTAL% | OK: %MOD_OK% | ATENCAO: %MOD_WARN% | ERRO: %MOD_ERR% | PULADOS: %MOD_SKIP%"
if not "%MOD_ERR%"=="0" call :LOG_MSG "ERR" "%MOD_ERR% modulo(s) terminaram em erro nesta sessao."
if not "%MOD_WARN%"=="0" call :LOG_MSG "WARN" "%MOD_WARN% modulo(s) terminaram com atencao nesta sessao."
goto :EOF

:SAIR_CLI
call :LOG_MSG "INFO" "SESSAO EM LINHA DE COMANDO ENCERRADA."
goto FIM

:FIM
call :RESUMO_SESSAO
:: Encerramento normal: marca o trace como limpo para que a proxima execucao
:: saiba que nao houve queda.
call :TRACE "ENCERRAMENTO NORMAL"

:: Codigo de saida semantico, no mesmo vocabulario dos modulos:
::   0 = tudo concluido | 1 = concluido com atencao | 2 = houve erro
::
:: Aplicado somente em modo linha de comando. E ali que o codigo e consumido -
:: RMM, GPO e tarefa agendada decidem por ele. Ate aqui o Launcher devolvia 0
:: mesmo quando todos os modulos falhavam, e a automacao registrava sucesso de
:: uma execucao que nao reparou nada.
::
:: No modo interativo o codigo continua 0: quem encerra e o operador, o valor
:: nao e lido por ninguem, e altera-lo poderia surpreender quem ja embrulha o
:: Launcher em outro script.
set "RC_FINAL=0"
if not defined CLI_MODE goto FIM_SAIDA
if not "%MOD_WARN%"=="0" set "RC_FINAL=1"
if not "%MOD_ERR%"=="0" set "RC_FINAL=2"
if not "%RC_FINAL%"=="0" call :LOG_MSG "INFO" "Codigo de saida: %RC_FINAL% (0=OK 1=atencao 2=erro)"

:FIM_SAIDA
:: Sob o guardiao (cmd /c "... & pause") e preciso encerrar o processo inteiro,
:: caso contrario o "pause" de seguranca dispararia apos uma saida legitima.
if defined COMPARTDISK_GUARD exit %RC_FINAL%
exit /b %RC_FINAL%

:SEM_EXTENSOES
:: Sem Command Extensions nao existem CALL :rotulo, SETLOCAL ou %~dp0. Nada da
:: ferramenta funciona; e melhor dizer isso claramente do que fechar em silencio.
echo.
echo [ERRO] As Command Extensions do interpretador de comandos estao desativadas.
echo        O COMPARTDISK depende delas em toda a sua estrutura.
echo.
echo        Execute:  cmd.exe /E:ON /C "%~f0"
echo.
pause
exit /b 1
