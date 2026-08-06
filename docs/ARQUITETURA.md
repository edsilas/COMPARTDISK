# Arquitetura da Aplicação

**COMPARTDISK 1.3.0** · Desenvolvido por Edsilas

---

## O princípio

O arquivo `.bat` **é o programa**. Ele detém a interface, os menus, a navegação, a
autoelevação, a detecção de ambiente e o controle de fluxo.

O PowerShell é um **motor acoplável**. Quando existe, assume as operações complexas:
consultas WMI e CIM, interfaces COM, tratamento estruturado de erros e geração de
relatórios. Quando não existe, o Batch executa a mesma funcionalidade por rotinas
próprias.

> **Regra de ouro do projeto:** nenhuma funcionalidade deixa de existir por ausência
> de PowerShell.

---

## Visão geral

```
Launcher.bat ──► interface, menus, UAC, detecção, fluxo, rotinas :FB_*
      │
      ├─ escolha do motor ──► pwsh 7 ► powershell 5.1 ► Batch puro
      │
      └─ Modules\*.ps1 ──► Core.ps1 ──► Collectors.ps1
                              │
                              └──► log, constatações, seções, relatórios
```

---

## Fluxo de inicialização

```
 1. Command Extensions verificadas
 2. Trace de bootstrap iniciado
 3. Interface preparada (cores, título)
 4. Sentinela de reentrada consumida, se presente
 5. Privilégio administrativo detectado em camadas
 6. Elevação solicitada, se necessário
 7. Diretório de gravação escolhido e testado
 8. Motor PowerShell selecionado e validado na prática
 9. Ferramentas nativas verificadas
10. Identificador de sessão gerado
11. Contexto exportado para os módulos
12. Menu principal exibido
```

Cada etapa registra uma linha no arquivo `%TEMP%\COMPARTDISK_Bootstrap.log`. Se a
partida falhar, a última linha aponta exatamente onde.

### Detecção de privilégio

A verificação é feita em três camadas, nesta ordem:

1. `fltmc` — a mais confiável, não depende de nenhum serviço
2. `net session` — alternativa
3. Escrita de teste em `HKLM` — última verificação

`net session` **não** é usado isoladamente porque falha quando o serviço *Server* está
parado ou desabilitado — comum em Windows Home e imagens corporativas endurecidas.
Nesse cenário, um administrador legítimo seria classificado como usuário comum.

### Reentrada após elevação

A instância elevada é iniciada com a sentinela interna `/elevated`. Se, mesmo após o
UAC, o privilégio não for confirmado, a ferramenta **avisa e prossegue em modo
degradado** — em vez de se relançar indefinidamente.

A reexecução ocorre sob um processo guardião. Em falha catastrófica, a janela
permanece aberta exibindo o erro, em vez de fechar instantaneamente.

---

## Seleção do motor

| Ordem | Motor | Detecção |
|---|---|---|
| 1 | PowerShell 7 | Caminho padrão de instalação, depois busca no PATH |
| 2 | Windows PowerShell 5.1 | Responde a uma execução de teste |
| 3 | Batch puro | Nenhum dos anteriores respondeu |

O motor escolhido é **validado na prática** com uma execução real, o que detecta
bloqueios por política de execução, AppLocker ou WDAC — casos em que o executável
existe mas se recusa a rodar.

---

## Contrato entre Batch e PowerShell

A comunicação usa variáveis de ambiente, herdadas pelo processo filho:

| Variável | Conteúdo |
|---|---|
| `COMPARTDISK_ROOT` | Pasta raiz da ferramenta |
| `COMPARTDISK_LOGDIR` | Diretório de gravação já validado |
| `COMPARTDISK_LOGFILE` | Caminho do log consolidado |
| `COMPARTDISK_SESSION` | Identificador da sessão |
| `COMPARTDISK_ENGINE` | Nome do motor em uso |
| `COMPARTDISK_TRACE` | Caminho do trace de inicialização |

### Códigos de saída

| Código | Significado | Ação do Launcher |
|---|---|---|
| `0` | Sucesso | Segue o fluxo |
| `1` | Concluído com avisos | Segue, registrando aviso |
| `2` | Erro tratado | Registra erro, segue |
| `3` | Não suportado no hardware ou edição | Registra aviso |
| `9001` | PowerShell indisponível | **Executa a rotina Batch equivalente** |
| `9002` | Módulo não encontrado | **Executa a rotina Batch equivalente** |

### Padrão de invocação

```bat
:MOD_REDE_RESET
set "PS_ARGS=-Action Reset"
call :RUN_PS "Network.ps1"
if errorlevel 9000 goto FB_REDE_RESET
goto :EOF
```

Os argumentos trafegam pela variável `PS_ARGS`, e não como parâmetro direto. Isso
evita o aninhamento de aspas do interpretador de comandos, origem clássica de falhas
em scripts híbridos.

---

## Camadas do PowerShell

```
┌──────────────────────────────────────────────────┐
│  Módulos de domínio (17)                         │
│  Network, Repair, Update, Defender, Cleanup...   │
│  Executam ações. Alteram o sistema.              │
└──────────────────────┬───────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────┐
│  Collectors.ps1                                  │
│  Coleta de dados. Somente leitura.               │
└──────────────────────┬───────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────┐
│  Core.ps1                                        │
│  Log, erros, testes de ambiente, relatórios      │
└──────────────────────────────────────────────────┘
```

A separação entre coleta e ação é o que permite a `Audit.ps1` e a `Report.ps1`
reaproveitarem tudo sem duplicar consulta, e garante que uma auditoria jamais altere
o sistema.

---

## Tratamento de erros

Todo módulo segue a mesma estrutura:

```powershell
$ErrorActionPreference = 'Stop'
try {
    Start-CompartDiskModule ...
    switch ($Action) { ... }
} catch {
    $result = 'ERROR'
    Write-Log ERR "..." -ErrorRecord $_
} finally {
    $codigo = Stop-CompartDiskModule -Result $result
}
exit $codigo
```

Nenhuma exceção é silenciada. Cada uma é registrada com tipo, código, mensagem e
rastreamento de pilha.

Consultas ao sistema usam uma cadeia de tentativas: CIM, depois WMI, depois CIM sobre
DCOM. Isso mantém a leitura funcionando em máquinas com o serviço WMI degradado.

---

## Relatórios

Ao final da execução, cada módulo persiste seu estado. `Report.ps1` agrega esses
estados e emite quatro formatos:

| Formato | Destino |
|---|---|
| TXT | Leitura direta, anexo em chamado |
| CSV | Planilha, inventário de parque |
| JSON | Integração com sistemas de gestão |
| HTML | Relatório visual completo |

O HTML é **totalmente offline**: estilos e comportamento embutidos, sem qualquer
recurso externo, usando apenas fontes já presentes no Windows.

---

## Fronteiras entre módulos que se tocam

Quatro módulos atuam sobre temas vizinhos. A divisão é explícita para que não existam
duas fontes de verdade para o mesmo alvo:

| Módulo | Território exclusivo |
|---|---|
| `Cleanup.ps1` | Arquivos temporários, caches de navegador, logs de eventos, dumps |
| `Telemetry.ps1` | Dois serviços de telemetria, cinco chaves de política, seis tarefas de coleta clássica |
| `Performance.ps1` | Plano de energia, efeitos visuais, análise de inicialização e processos |
| `Debloat.ps1` | Aplicativos da loja, quinze serviços, quatorze tarefas, ajustes de interface, componentes obsoletos |

O `Debloat.ps1` **não** reimplementa nada dos outros três. Onde há sobreposição
temática, ele delega e registra a delegação no log: a limpeza de temporários aponta
para o Cleanup, a telemetria aponta para o Telemetry.

Essa separação é o que permite executar qualquer combinação de módulos sem que um
desfaça o trabalho do outro.

---

## Princípios de projeto aplicados

| Princípio | Como aparece |
|---|---|
| Responsabilidade única | Cada módulo cobre um domínio; coleta e ação são separadas |
| Não se repita | Coletores compartilhados entre auditoria, relatório e módulos |
| Programação defensiva | Toda entrada externa é validada; caminhos críticos são protegidos |
| Falha segura | Erro em um módulo não derruba a sessão |
| Idempotência | Reexecutar uma ação não piora o estado |
| Compatibilidade retroativa | Rotinas de contingência para cada função |

---

[Voltar ao índice](../README.md) · Próximo: [Manual Técnico](MANUAL-TECNICO.md)
