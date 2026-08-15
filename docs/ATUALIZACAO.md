# Política de Atualização

**COMPARTDISK 1.4.1** · Desenvolvido por Edsilas

---

## Como atualizar

1. Baixe a versão nova na página oficial de *Releases*:
   **https://github.com/edsilas/COMPARTDISK/releases**
2. Extraia em uma pasta nova
3. Copie seus relatórios antigos, se quiser guardá-los
4. Apague a pasta antiga

**Não é necessário desinstalar nada.** Não há registro no sistema, não há serviços,
não há entradas de inicialização.

### Atualizando por cima

Também funciona: extraia sobre a pasta existente, substituindo os arquivos. Seus
relatórios e o log são preservados, porque têm nomes diferentes dos arquivos do
programa.

> Substitua **toda** a pasta `Modules`. Misturar módulos de versões diferentes com um
> `Launcher.bat` de outra versão não é suportado.

---

## Como saber qual versão você tem

No topo da tela principal, ou no menu `9` → campo **Versão**.

---

## Numeração de versões

O projeto segue [Versionamento Semântico](https://semver.org/lang/pt-BR/), no formato
**MAIOR.MENOR.CORREÇÃO**:

| Parte | Muda quando |
|---|---|
| **MAIOR** | Há mudança incompatível — teclas de menu diferentes, formato de relatório alterado |
| **MENOR** | Novas funcionalidades são adicionadas, mantendo tudo que existia |
| **CORREÇÃO** | Apenas correções de falhas |

Exemplo: da versão **1.3.1** para **1.4.0**, a instalação de aplicativos foi
acrescentada e nada foi removido — a atualização de programas que já existia continua
funcionando exatamente como antes.

O histórico completo, versão por versão, está no
[Changelog](../CHANGELOG.md) e nas notas de cada publicação em
[Releases](https://github.com/edsilas/COMPARTDISK/releases).

---

## Compromissos do projeto

Em atualizações **menores** e de **correção**:

- Nenhuma funcionalidade é removida.
- As teclas dos menus não mudam de posição.
- Os fluxos de execução permanecem os mesmos.
- Os formatos de relatório continuam legíveis.
- A compatibilidade com Windows 10 e 11 é preservada.
- Os parâmetros de linha de comando continuam válidos.

Mudanças que quebrem qualquer um desses pontos só ocorrem em versão **MAIOR**, e são
descritas em detalhe no [CHANGELOG](../CHANGELOG.md).

---

## Verificando o que mudou

O arquivo [CHANGELOG.md](../CHANGELOG.md) registra cada versão, separando o que foi
**adicionado**, **alterado**, **corrigido** e **mantido**.

---

## Compatibilidade de arquivos gerados

| Arquivo | Entre versões |
|---|---|
| `Relatorio_Manutencao.txt` | Continua sendo acrescido, sem quebra |
| Relatórios TXT, CSV, JSON, HTML | Formatos estáveis; campos podem ser acrescentados, nunca removidos |
| `COMPARTDISK_Bootstrap.log` | Reescrito a cada execução |

Relatórios gerados por versões anteriores continuam abrindo normalmente.

---

## Reportando problemas em uma atualização

Abra uma *issue* em https://github.com/edsilas/compartdisk/issues informando:

- a versão anterior e a nova;
- o que funcionava antes e parou de funcionar;
- o arquivo `%TEMP%\COMPARTDISK_Bootstrap.log`;
- o relatório HTML, se conseguir gerá-lo.

---

[Voltar ao índice](../README.md) · Próximo: [Créditos](CREDITOS.md)
