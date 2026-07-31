# Compatibilidade

**COMPARTDISK 1.2.0** · Desenvolvido por Edsilas

---

## Versões do Windows

| Versão | Situação |
|---|---|
| Windows 11 (todas as versões) | Suportado |
| Windows 10 versão 1809 e superiores | Suportado |
| Windows 10 anteriores a 1809 | Funciona, com recursos reduzidos |
| Windows 8.1 e anteriores | Não suportado |
| Windows Server | Não é o alvo do projeto; a maior parte funciona |

## Edições

| Edição | Situação |
|---|---|
| Home | Suportada integralmente |
| Pro | Suportada integralmente |
| Education | Suportada integralmente |
| Enterprise | Suportada integralmente |
| Pro for Workstations | Suportada integralmente |

### Diferenças entre edições

Alguns recursos simplesmente não existem em determinadas edições. A ferramenta
detecta isso e informa, em vez de falhar:

| Recurso | Home | Pro / Education / Enterprise |
|---|---|---|
| BitLocker | Apenas criptografia de dispositivo | Completo |
| Diretivas de grupo locais | Não disponível | Disponível |
| Hyper-V e virtualização | Limitado | Disponível |
| Demais funções da ferramenta | Disponíveis | Disponíveis |

---

## Arquiteturas

| Arquitetura | Situação |
|---|---|
| x64 (Intel e AMD 64 bits) | Suportada |
| ARM64 | Suportada |
| x86 (32 bits) | Funciona, mas o Windows 10/11 de 32 bits está descontinuado |

---

## Motores de execução

| Motor | Situação |
|---|---|
| Windows PowerShell 5.1 | Suportado — é o que acompanha o Windows |
| PowerShell 7.x | Suportado e preferido quando presente |
| Somente Batch | Suportado — todas as funções permanecem acessíveis |

A escolha é automática. O motor é testado na prática antes de ser usado, o que
detecta bloqueios por política de execução, AppLocker ou WDAC.

---

## Idiomas do Windows

A ferramenta funciona em **qualquer idioma** do Windows.

Isso não é trivial em scripts de manutenção, e exigiu decisões específicas:

- A conta interna de Administrador é localizada pelo identificador de segurança
  (SID terminado em `-500`), e não pelo nome. Procurar por "Administrator" falharia
  em Windows português, e "Administrador" falharia em Windows inglês.
- A verificação de disco usa comandos não interativos, sem depender de confirmação
  por tecla `S` ou `Y`, que varia com o idioma.
- Os textos da interface estão em português, sem acentuação, para exibição correta
  em qualquer página de código do console.

---

## Ambientes corporativos

| Cenário | Comportamento |
|---|---|
| Máquina em domínio | Funciona normalmente |
| Política de execução restritiva | Detectada; fallback Batch é usado |
| AppLocker ou WDAC bloqueando scripts | Detectado; fallback Batch é usado |
| Windows Script Host desativado | Elevação por PowerShell; se também bloqueado, elevação manual |
| Execução de compartilhamento de rede | Funciona; relatórios vão para a Área de Trabalho |
| Pen drive protegido contra gravação | Detectado; relatórios vão para a Área de Trabalho |
| Antivírus corporativo | Pode alertar; adicione às exclusões se apropriado |

> Em máquinas gerenciadas por política corporativa, as opções do menu `6` podem
> desfazer configurações aplicadas de propósito pela organização. Confirme com o
> setor de TI antes de usá-las.

---

## Compatibilidade entre versões da ferramenta

O projeto mantém compatibilidade retroativa de comportamento:

- As sequências de teclas dos menus não mudam entre versões menores.
- Arquivos de log e relatórios de versões anteriores continuam legíveis.
- Nenhuma funcionalidade é removida em atualizações menores ou de correção.

Veja [Política de Atualização](ATUALIZACAO.md).

---

[Voltar ao índice](../README.md) · Próximo: [Limitações Conhecidas](LIMITACOES.md)
