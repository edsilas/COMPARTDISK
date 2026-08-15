# Manual do Administrador

**COMPARTDISK 1.4.2** · Desenvolvido por Edsilas

Para quem administra parque de computadores.

---

## Implantação

Não há instalador nem dependências. A implantação consiste em disponibilizar a pasta.

### Opções

| Cenário | Como fazer |
|---|---|
| Uso pontual | Cópia local em `C:\COMPARTDISK` |
| Parque pequeno | Pasta em compartilhamento de rede, executada de lá |
| Parque grande | Distribuição por GPO, SCCM, Intune ou ferramenta de RMM |

Executando de um compartilhamento somente-leitura, a ferramenta detecta que não pode
gravar e desvia os relatórios para a Área de Trabalho do usuário. Para centralizar,
defina o destino explicitamente.

---

## Execução desassistida

```bat
Launcher.bat /audit      :: auditoria completa com os quatro relatórios
Launcher.bat /autofix    :: reparo geral automático
Launcher.bat /report     :: apenas consolidação dos relatórios
Launcher.bat /clean      :: limpeza profunda
```

Em modo desassistido não há menus nem pausas. O processo encerra com código de saída
`0`, o que permite encadeamento em scripts.

### Coleta centralizada

```bat
@echo off
set "COMPARTDISK_LOGDIR=\\servidor\inventario\%COMPUTERNAME%\"
\\servidor\ferramentas\compartdisk\Launcher.bat /audit
```

Cada máquina grava em sua própria subpasta. Os arquivos `.csv` e `.json` são pensados
para consumo automatizado.

### Tarefa agendada

```
Programa:   C:\COMPARTDISK\Launcher.bat
Argumentos: /audit
Executar:   com privilégios mais altos
Conta:      SYSTEM ou conta de serviço administrativa
```

Executando como SYSTEM, o Controle de Conta de Usuário não é acionado.

---

## Distribuição por GPO

**Configuração do Computador → Preferências → Configurações do Windows → Arquivos**
para copiar a pasta, e uma tarefa agendada para a execução.

Alternativamente, um script de inicialização que invoque `Launcher.bat /audit`.

> Scripts de inicialização executam como SYSTEM, o que dispensa elevação — mas também
> significa que a Área de Trabalho do usuário não estará disponível como destino de
> gravação. Defina `COMPARTDISK_LOGDIR`.

---

## Comportamento em ambiente gerenciado

| Restrição | Comportamento |
|---|---|
| Política de execução do PowerShell restritiva | Detectada; rotinas Batch assumem |
| AppLocker ou WDAC bloqueando scripts | Detectado; rotinas Batch assumem |
| Windows Script Host desativado | Elevação por PowerShell; se também bloqueado, orienta elevação manual |
| Serviço *Server* desabilitado | Detecção de privilégio usa `fltmc`, não é afetada |
| WMIC removido | Caminhos alternativos são usados |
| Pasta somente-leitura | Desvia para Área de Trabalho, depois pasta temporária |

A ferramenta **nunca** falha silenciosamente por causa dessas restrições: cada uma é
detectada, registrada no log e contornada.

---

## Considerações de segurança

### Superfície de execução

- Apenas arquivos de texto. Não há binários compilados.
- Nenhuma conexão de saída, exceto nas funções que existem para isso.
- Nada é baixado ou instalado.
- Não cria serviços, tarefas agendadas próprias ou entradas de inicialização.

### Operações que exigem atenção

Estas opções podem conflitar com políticas corporativas:

| Opção | Risco |
|---|---|
| Menu `6` → `1` Resetar GPO Local | Remove diretivas locais aplicadas pela organização |
| Menu `6` → `2` Gerenciar Contas | Permite alterar senhas e ativar a conta interna de Administrador |
| Menu `6` → `4` Assumir Controle | Altera propriedade e permissões de arquivos |
| Menu `4` → `2` Desativar Telemetria | Pode afetar inventário e conformidade |

Considere restringir o acesso à ferramenta, ou orientar as equipes sobre o uso do
menu `6`.

### Dados nos relatórios

Os relatórios contêm nome do computador, nome de usuário, domínio, número de série do
equipamento, lista de programas instalados e configuração de rede.

**Não contêm** senhas, arquivos pessoais nem histórico de navegação. Chaves de
recuperação do BitLocker são exibidas na tela quando solicitadas, mas nunca gravadas
em arquivo.

Trate os relatórios conforme a política de classificação de informação da organização.

---

## Desbloat em ambiente gerenciado

O módulo é interativo por desenho: exige confirmação em tela nos níveis Moderado e
Avançado, e não está exposto nos parâmetros de linha de comando. Isso é deliberado —
remover aplicativos de um parque inteiro sem revisão prévia é uma decisão que não deve
caber a um parâmetro.

### Se for usar mesmo assim

O módulo pode ser chamado diretamente, fora do Launcher:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "\\servidor\compartdisk\Modules\Debloat.ps1" -Action Full -Level Safe -Quiet
```

| Recomendação | Motivo |
|---|---|
| Valide numa máquina-piloto antes | O catálogo é o mesmo, mas o parque não é homogêneo |
| Use `-Action Analyze` e colete o JSON primeiro | Você vê o que sairia em cada máquina, antes de decidir |
| Prefira `-Level Safe` | Os níveis acima removem aplicativos que setores diferentes usam de forma diferente |
| Use `-Exclude` para o que sua organização usa | Ex.: `-Exclude '*Xbox*','Microsoft.Windows.Photos'` |
| Não use `-SkipRestorePoint` | Ele existe para casos excepcionais, não para produção |
| Colete os manifestos | Ficam em `COMPARTDISK_Restauracao` e são a base de qualquer reversão |

### Conflito com políticas de grupo

Ajustes de privacidade gravados em `HKLM\SOFTWARE\Policies` podem ser sobrescritos no
próximo ciclo de GPO, se a organização gerencia essas chaves. O módulo grava sem erro e
a política vence depois. Não há conflito destrutivo, apenas o valor não persiste.

### O que não fazer

Não distribua o nível Avançado por GPO. O `/ResetBase` impede desinstalar atualizações
já aplicadas, de forma definitiva e em toda a frota ao mesmo tempo.

A referência completa está no [Módulo de Desbloat](DESBLOAT.md).

---

## Monitoramento e diagnóstico

### Códigos de saída

| Código | Significado |
|---|---|
| `0` | Sucesso |
| `1` | Concluído com avisos |
| `2` | Erro tratado |

Úteis para condicionar etapas em scripts de implantação.

### Arquivos de diagnóstico

| Arquivo | Uso |
|---|---|
| `Relatorio_Manutencao.txt` | Histórico acumulado de tudo que foi executado |
| `COMPARTDISK_Relatorios/<sessão>/*.json` | Consumo automatizado, integração com sistemas de gestão |
| `COMPARTDISK_Relatorios/<sessão>/*.csv` | Inventário em planilha |
| `%TEMP%\COMPARTDISK_Bootstrap.log` | Diagnóstico de falha de partida |

### Estrutura do JSON

```json
{
  "Meta":     { "Ferramenta": "...", "Autor": "...", "Computador": "...", ... },
  "Sections": [ { "Title": "...", "Status": "...", "Rows": [...] } ],
  "Findings": [ { "Severity": "CRIT", "Area": "...", "Recommendation": "..." } ]
}
```

O campo `Findings` é o mais útil para alertas automatizados: filtre por
`Severity = "CRIT"` para identificar máquinas que exigem atenção.

---

## Atualização do parque

Substitua a pasta inteira. Não misture módulos de versões diferentes com um
`Launcher.bat` de outra versão.

Consulte a [Política de Atualização](ATUALIZACAO.md) para os compromissos de
compatibilidade entre versões.

---

[Voltar ao índice](../README.md) · Próximo: [Manual Técnico](MANUAL-TECNICO.md)
