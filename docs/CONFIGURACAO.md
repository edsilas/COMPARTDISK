# Guia de Configuração

**COMPARTDISK 1.2.0** · Desenvolvido por Edsilas

O COMPARTDISK funciona sem qualquer configuração. Este guia existe para quem quer
saber **onde as coisas ficam** e **como ajustar** o comportamento padrão.

---

## Onde ficam os arquivos gerados

A ferramenta escolhe sozinha o melhor lugar para gravar, testando nesta ordem:

| Ordem | Local | Quando é usado |
|---|---|---|
| 1 | A própria pasta do `Launcher.bat` | Sempre que a pasta aceitar gravação |
| 2 | Sua Área de Trabalho | Quando a pasta do programa é somente-leitura (pen drive protegido, compartilhamento de rede) |
| 3 | A pasta temporária do Windows | Último recurso |

O teste é de **gravação real**, não apenas de existência — um pen drive protegido
contra escrita aceita ser lido mas recusa a gravação, e a ferramenta detecta isso.

Para saber qual local foi escolhido nesta execução, veja o rodapé do menu principal
ou abra a tela **[9] Ambiente de Execução**.

## Quais arquivos são criados

| Arquivo | O que contém |
|---|---|
| `Relatorio_Manutencao.txt` | Log de tudo que foi feito, acumulado entre execuções |
| `COMPARTDISK_Relatorios\<sessão>\` | Relatórios da sessão em TXT, CSV, JSON e HTML |
| `COMPARTDISK_Bootstrap.log` | Diagnóstico da inicialização (na pasta temporária) |

Cada sessão cria sua própria subpasta, identificada por data e hora
(`20260731_143052`). Sessões antigas nunca são apagadas automaticamente — se quiser
liberar espaço, apague as subpastas manualmente.

## Motor de execução

Na partida, a ferramenta escolhe automaticamente o motor mais capaz disponível:

| Ordem | Motor | Efeito |
|---|---|---|
| 1 | PowerShell 7 | Diagnóstico mais completo e rápido |
| 2 | Windows PowerShell 5.1 | Diagnóstico completo (é o que vem no Windows) |
| 3 | Somente Batch | Todas as funções continuam disponíveis, com diagnóstico mais simples |

Não há nada a configurar: a escolha é automática e o motor em uso aparece no rodapé
do menu principal.

O motor escolhido é ainda **testado na prática** antes de ser usado, o que detecta
bloqueios por política de execução, AppLocker ou WDAC — situações em que o programa
existe mas se recusa a rodar.

---

## Ajustes possíveis

Não há arquivo de configuração. Os ajustes são feitos por variáveis de ambiente,
úteis principalmente em execução automatizada.

| Variável | Para que serve |
|---|---|
| `COMPARTDISK_LOGDIR` | Força um diretório específico para os arquivos gerados |
| `COMPARTDISK_DEBUG` | Quando definida, registra mensagens de depuração no log |

Exemplo — gravar tudo em uma pasta de rede:

```bat
set "COMPARTDISK_LOGDIR=\\servidor\manutencao\logs\"
Launcher.bat /audit
```

> Estas variáveis são opcionais. Sem elas, a ferramenta usa os padrões descritos acima.

## Parâmetros de linha de comando

Para executar sem passar pelos menus:

| Parâmetro | O que faz |
|---|---|
| `/autofix` | Executa o reparo geral automático e encerra |
| `/audit` | Executa a auditoria completa, gera os relatórios e encerra |
| `/report` | Apenas consolida e gera os relatórios |
| `/clean` | Executa a limpeza profunda |
| `/?` | Mostra a ajuda |

Exemplo:

```bat
Launcher.bat /audit
```

Detalhes de uso em parque de máquinas no
[Manual do Administrador](MANUAL-DO-ADMINISTRADOR.md).

---

## O que a ferramenta **não** altera

Para deixar claro, o COMPARTDISK nunca:

- instala serviços ou tarefas agendadas próprias;
- adiciona itens à inicialização do Windows;
- grava configurações permanentes fora dos arquivos listados acima;
- envia qualquer dado para a internet;
- permanece em execução depois de fechada.

---

[Voltar ao índice](../README.md) · Próximo: [Guia de Utilização](UTILIZACAO.md)
