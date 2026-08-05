# Descrição das Funcionalidades

**COMPARTDISK 1.2.0** · Desenvolvido por Edsilas

Descrição técnica do que cada recurso faz. Para a explicação em linguagem simples,
veja o [Manual do Usuário](MANUAL-DO-USUARIO.md).

---

## Matriz de módulos e ações

| Módulo | Ações |
|---|---|
| `Network.ps1` | `Info` `Reset` `Hosts` `Firewall` `Test` `Proxy` `Wifi` |
| `Repair.ps1` | `Full` `Sfc` `Dism` `Scan` `Chkdsk` `Component` |
| `Update.ps1` | `Status` `History` `Reset` `Cache` `Services` `Search` |
| `Defender.ps1` | `Status` `Update` `QuickScan` `FullScan` `CustomScan` `Exclusions` `History` |
| `Cleanup.ps1` | `Analyze` `Standard` `Deep` `Browsers` `Logs` |
| `Security.ps1` | `Status` `GpoReset` `Takeown` `Firewall` `Uac` |
| `Users.ps1` | `List` `Groups` `Audit` `ClearPassword` `SetPassword` `EnableAdmin` `DisableAdmin` |
| `Telemetry.ps1` | `Status` `Disable` `Enable` |
| `Debloat.ps1` | `Analyze` `Apps` `Services` `Tasks` `Privacy` `Tweaks` `Components` `Full` `Backup` `Restore` `RestorePoint` |
| `Performance.ps1` | `Analyze` `Ultimate` `Balanced` `Startup` `Processes` `Services` |
| `Hardware.ps1` | `Info` `Full` `Gpu` `Memory` `Devices` `Temperature` |
| `Drivers.ps1` | `List` `Problems` `Backup` `Unsigned` `Export` |
| `Smart.ps1` | `Status` `Detail` `Volumes` `Shadow` `Spaces` |
| `Battery.ps1` | `Info` `Report` `Sleep` |
| `Bitlocker.ps1` | `Status` `Report` `Keys` |
| `Explorer.ps1` | `Restart` `ClearCache` `Spooler` `ResetView` |
| `Audit.ps1` | `Full` `Quick` `Events` `Software` `License` |
| `Report.ps1` | `Build` `Consolidate` `Open` |

---

## Rede e conectividade

**Reset completo** executa nove passos: liberação e renovação de endereço, limpeza do
cache de nomes, reinicialização do Winsock, do TCP/IP e do IPv6, limpeza da tabela
ARP, remoção do proxy do WinHTTP e novo registro no DNS.

**Arquivo hosts** é restaurado ao conteúdo padrão da Microsoft, com cópia do anterior
gravada antes.

**Firewall** é exportado para arquivo `.wfw` antes de qualquer reset, e os três perfis
são reativados ao final.

**Diagnóstico** cobre adaptadores, endereçamento, servidores DNS, concessão DHCP,
unidade máxima de transmissão e tabela de rotas.

**Teste de conectividade** verifica em três níveis: resposta ICMP, resolução de nomes
e requisição HTTP — o que permite identificar em qual camada a conexão falha.

---

## Reparo do sistema

**Reparo profundo** executa, em ordem: verificação da imagem, restauração da imagem e
verificação dos arquivos de sistema. A análise do registro do verificador identifica
quantos arquivos foram efetivamente reparados.

**Verificação de disco** usa comandos não interativos. A implementação original em
Batch dependia de confirmação por tecla, o que falhava conforme o idioma do Windows.

**Windows Update** — o reset renomeia as pastas de distribuição e de catálogo para
`.old`, em vez de apagá-las, permitindo reversão manual. Vinte e uma bibliotecas são
registradas novamente e uma nova busca é disparada.

**Explorer** — reinício do processo, reconstrução do cache de ícones e miniaturas, e
limpeza da fila de impressão.

---

## Limpeza

**Modo de análise** é uma simulação: percorre todos os alvos, mede o espaço ocupado e
apresenta o total recuperável **sem apagar nada**.

**Alvos por grupo:**

| Grupo | Conteúdo |
|---|---|
| Padrão | Temporários do usuário e do sistema, lixeira, prefetch |
| Profundo | Cache de atualizações, otimização de entrega, perfis antigos |
| Navegadores | Cache de Edge, Chrome, Brave e Firefox, em todos os perfis |
| Registros | Logs de eventos, despejos de memória, relatórios de erro |

A limpeza de registros exporta os logs para arquivos `.evtx` antes de limpá-los.

A remoção de arquivos passa por uma função com lista de caminhos protegidos, que
nunca remove a pasta do Windows, `System32` ou raiz de unidade.

---

## Segurança

**Postura de segurança** reporta Secure Boot, TPM, segurança baseada em virtualização,
proteção de credenciais, integridade de código, integridade de memória, proteção do
processo de autoridade de segurança local, Controle de Conta de Usuário, SmartScreen e
Windows Hello.

**Defender** — estado do serviço, versão das assinaturas, proteção em tempo real,
proteção na nuvem, envio de amostras, exclusões configuradas e histórico de ameaças.
Exclusões são sinalizadas como possível vetor de evasão.

**Diretivas de grupo** — as pastas são copiadas antes do reset.

**Assumir controle** recusa caminhos críticos do sistema, mesmo com privilégio
administrativo.

**Contas locais** — a conta interna de Administrador é localizada pelo identificador
de segurança terminado em `-500`, e não pelo nome, o que funciona em qualquer idioma.
Remover a senha de uma conta exige digitar literalmente a palavra `REMOVER`, e o ato é
registrado no log como evento de segurança.

---

## Hardware e discos

**Saúde de discos** combina o estado reportado pelo subsistema de armazenamento com os
contadores de confiabilidade: horas ligado, ciclos de carga, dados lidos e escritos,
setores realocados e temperatura, quando disponível.

**Inventário completo** cobre processador, módulos de memória individualmente, placa de
vídeo, monitores com identificação decodificada, dispositivos USB e PCI, placa-mãe,
BIOS e TPM.

**Bateria** calcula o desgaste real comparando a capacidade de projeto com a capacidade
de carga completa atual. Gera também o relatório de bateria e o diagnóstico de energia
do próprio Windows.

**Drivers** — inventário completo, dispositivos com código de erro, drivers sem
assinatura digital e backup por exportação, com verificação prévia de espaço livre.

**BitLocker** é somente leitura. Chaves de recuperação podem ser exibidas na tela, mas
**nunca são gravadas em arquivo**.

---

## Diagnóstico e relatórios

**Auditoria rápida** cobre sistema, hardware, discos, rede, segurança, antivírus,
BitLocker e Windows Update.

**Auditoria completa** acrescenta drivers, contas, serviços, processos, energia,
licenciamento, aplicativos instalados, eventos e integridade — e emite os quatro
formatos de relatório.

**Consolidação** agrega o estado de todos os módulos executados na sessão em um
relatório único.

Cada constatação recebe uma severidade — crítico, atenção, conforme ou informativo — e
uma recomendação de ação. O resumo executivo contabiliza cada categoria.

---

## Registro

Cada entrada de log contém data, hora, computador, usuário, versão e build do Windows,
versão do PowerShell, módulo de origem, tempo de execução, resultado, e — em caso de
exceção — o tipo, o código e o rastreamento de pilha.

O escritor de log higieniza caracteres que o interpretador de comandos trataria como
operadores, o que garante que nenhuma mensagem possa corromper o arquivo.

---

## Modo desassistido

| Parâmetro | Efeito |
|---|---|
| `/autofix` | Reparo geral automático |
| `/audit` | Auditoria completa com os quatro relatórios |
| `/report` | Consolidação e emissão dos relatórios |
| `/clean` | Limpeza profunda |
| `/?` | Ajuda |

---

[Voltar ao índice](../README.md) · Próximo: [Manual do Administrador](MANUAL-DO-ADMINISTRADOR.md)
