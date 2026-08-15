# Créditos

**COMPARTDISK 1.4.3**

---

## Autoria

**Desenvolvido por Edsilas**

Concepção, arquitetura, desenvolvimento e documentação do projeto.

Repositório oficial: https://github.com/edsilas/compartdisk

---

## Sobre o projeto

O COMPARTDISK nasceu de uma ferramenta de manutenção em Batch, de arquivo único, e
evoluiu para uma arquitetura modular híbrida que combina Batch e PowerShell — mantendo
a compatibilidade máxima do primeiro com a capacidade de diagnóstico do segundo.

O princípio que orienta o projeto: **nenhuma funcionalidade pode deixar de existir por
ausência de um componente opcional**. Cada operação disponível pelo PowerShell tem uma
rotina Batch equivalente. É por isso que a ferramenta funciona igualmente em uma
estação corporativa endurecida e em um Windows Home doméstico.

---

## Tecnologias utilizadas

O projeto usa **exclusivamente** componentes nativos do Windows. Não há dependências
de terceiros, bibliotecas externas ou pacotes de repositório.

| Componente | Uso |
|---|---|
| Interpretador de Comandos do Windows | Interface, menus, fluxo e rotinas de contingência |
| Windows PowerShell 5.1 / PowerShell 7 | Motor de operações, diagnóstico e relatórios |
| WMI e CIM | Consultas de hardware, sistema e segurança |
| DISM e SFC | Reparo de arquivos e imagem do Windows |
| Netsh e IPConfig | Configuração e diagnóstico de rede |
| PowerCfg | Energia, bateria e diagnóstico de suspensão |
| PnPUtil | Inventário e backup de drivers |
| Manage-bde | Consulta ao BitLocker |
| Windows Update Agent | Consulta de histórico e busca de atualizações |
| Microsoft Defender | Status, assinaturas e varreduras |

---

## Documentação

Documentação estruturada e escrita com prioridade para usuários não técnicos,
seguindo o princípio de que uma ferramenta de manutenção só é útil se a pessoa que
precisa dela conseguir usá-la sem medo.

Referências de formato adotadas:

- [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) — estrutura do histórico de mudanças
- [Versionamento Semântico](https://semver.org/lang/pt-BR/) — numeração de versões

---

## Licença

Distribuído sob a **Licença MIT**. Consulte o arquivo [LICENSE](../LICENSE) para os
termos completos.

Em resumo: você pode usar, copiar, modificar, distribuir e até comercializar, desde
que mantenha o aviso de direitos autorais. O software é fornecido sem garantias.

---

## Marcas registradas

Windows, Windows 10, Windows 11, PowerShell, Microsoft Defender e BitLocker são marcas
registradas da Microsoft Corporation. Este projeto não é afiliado, patrocinado ou
endossado pela Microsoft.

---

## Contribuições

Sugestões, relatos de falha e melhorias são bem-vindos em
https://github.com/edsilas/compartdisk/issues.

---

<div align="center">

**COMPARTDISK 1.4.3** — Desenvolvido por Edsilas

</div>
