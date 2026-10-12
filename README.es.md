# Slash Command

**Cambia el modelo y el esfuerzo (effort) de tu agente de programación con un solo atajo, sin salir de la conversación.**

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md)

Slash Command es una app de la barra de menús de macOS. Pulsa **⇧⌥1 … ⇧⌥9** en tu terminal y el agente de la sesión en primer plano cambia al **modelo + effort** de ese preajuste. **⇧⌥=** y **⇧⌥-** suben o bajan el effort un nivel.

Funciona con **Claude Code, Codex, Grok, Cursor Agent, Antigravity y OpenCode**, en **Ghostty, Orca, iTerm2, WezTerm y kitty**.

- **Una sola pulsación** en lugar de escribir `/model`, buscar la fila y fijar el effort.
- **En plena conversación.** Lo que estabas escribiendo se queda en el cuadro de entrada.
- **Solo en esta sesión.** Los valores predeterminados de tus sesiones nuevas no cambian.
- **Un número, todos los agentes.** El preajuste 1 puede significar Opus en Claude Code y un modelo GPT en Codex. La app mira qué agente está en primer plano.
- **Cuidadosa por diseño.** Solo envía teclas cuando ve el cuadro de entrada del agente, y se detiene cuando no está segura.

## Instalación

Requiere macOS 13 o posterior.

1. Descarga `Slash-Command.zip` desde la [última versión](https://github.com/yohangwak/slash-command/releases/latest), descomprímelo y mueve **Slash Command** a la carpeta Aplicaciones.
2. Ábrela. Aparecerá un icono con la tecla `/` en la barra de menús.
3. Abre **Ajustes…** desde ese icono y usa el cuadro **Permisos** de la parte superior. Sus botones abren por ti el panel correcto de Ajustes del Sistema.

| Permiso | Para qué sirve |
|---|---|
| **Accesibilidad** (macOS 27 lo muestra como *Device Control and Data Access*) | Leer la pantalla de Ghostty y comprobar que Broadcast Input de iTerm2 está desactivado |
| **Automatización** (Slash Command → Ghostty, Slash Command → iTerm2) | Escribir en la terminal. macOS lo pregunta la primera vez que pulsas un atajo allí |

WezTerm y kitty no necesitan ninguno de los dos, y Orca funciona sin ellos. kitty necesita tener activado el control remoto. Consulta [Terminals](docs/terminals.md).

Para que se inicie al iniciar sesión, activa **Abrir al iniciar sesión** en **General** dentro de Ajustes.

<details>
<summary>Compilar desde el código fuente</summary>

```sh
git clone https://github.com/yohangwak/slash-command.git
cd slash-command
./scripts/build-app.sh --install   # builds, copies to ~/Applications, links ~/.local/bin/slashcommand
```

Necesitas la cadena de herramientas de Swift (Xcode o las Command Line Tools). Sin un certificado de firma, la compilación se firma ad hoc y macOS vuelve a pedir los permisos después de cada recompilación.

</details>

## Uso

| Teclas | Qué ocurre |
|---|---|
| `⇧⌥1` … `⇧⌥9` | Cambia el agente en primer plano al modelo y al effort de ese preajuste |
| `⇧⌥=` / `⇧⌥-` | Mantiene el modelo y sube o baja el effort un nivel |

Un pequeño aviso en la parte inferior de la pantalla muestra lo que respondió el agente, por ejemplo `Opus 5.5 · high`. Los atajos solo están activos mientras hay una terminal compatible en primer plano, así que las mismas teclas conservan su significado habitual en otras apps. Puedes cambiar las teclas modificadoras en Ajustes.

El icono de la barra de menús muestra el agente de la sesión en primer plano y lo que haría cada preajuste con él.

## Preajustes

Edita los preajustes en **Ajustes… → Preajustes**, o edita directamente `~/.config/slashcommand/presets.json`.

```json
{
  "version": 1,
  "slots": [
    { "claude": { "model": "opus",   "effort": "high" }, "codex": { "model": "gpt-6-astra", "effort": "high" } },
    { "claude": { "model": "sonnet", "effort": "high" }, "codex": { "model": "gpt-6.1-sol", "effort": "high" } },
    { "name": "Nocturno", "claude": { "model": "fable", "effort": "max" } }
  ]
}
```

El número de un preajuste es una intención. Cada preajuste tiene una entrada por agente, y un atajo usa la entrada del agente que está en primer plano. Un preajuste sin entrada para ese agente no hace nada allí. Consulta [Presets](docs/presets.md) para ver todas las claves.

## Línea de comandos

La app incluye una herramienta de línea de comandos con la misma lógica de cambio.

```sh
slashcommand list              # the presets
slashcommand where             # the frontmost terminal and its agent
slashcommand doctor --screen   # check the target, screen reading and input box; sends nothing
slashcommand apply 2 --trace   # apply preset 2 and print the time per step
slashcommand run 2 claude      # open a new session with preset 2
```

## Qué es compatible

| Terminal | Notas |
|---|---|
| Ghostty | Necesita Accesibilidad y Automatización. tmux dentro de Ghostty aún no es compatible |
| Orca | Sin configuración. Accesibilidad es opcional y hace que el cambio de pestaña se registre al instante |
| iTerm2 | Necesita Automatización, y Accesibilidad para comprobar Broadcast Input |
| WezTerm | Sin configuración |
| kitty | Activa primero el control remoto |
| tmux | Dentro de Orca, iTerm2, WezTerm y kitty |

Terminal.app y la terminal de VS Code no son compatibles.

| Agente | Versiones comprobadas |
|---|---|
| Claude Code | 2.1.283 – 2.1.296 |
| Codex | 0.156.0 – 0.162.0 |
| Grok | 1.0.46, 1.0.50 |
| Cursor Agent | 2026.10.01 |
| Antigravity | 1.3.1, 1.3.3 |
| OpenCode | 1.18.35, 2.0.25 |

Slash Command maneja el selector de modelos de cada agente leyendo la pantalla, por lo que depende del texto que muestran esos selectores. Cuando un agente cambia ese texto, el cambio se detiene y no se envía nada más. `slashcommand doctor` te avisa cuando la versión que usas no se ha comprobado.

## Privacidad

Slash Command no tiene código de red. Lee la pantalla de la terminal solo para decidir qué enviar. Su registro (`~/Library/Logs/SlashCommand/slashcommand.log`) anota las teclas que pulsaste, el resultado y los tiempos. Nunca anota lo que había en la pantalla.

## Documentación

Estos documentos solo están en inglés.

- [Presets](docs/presets.md): el archivo de preajustes y cómo abrir sesiones nuevas con `run`
- [Terminals](docs/terminals.md): configuración y límites de cada terminal, y tmux
- [Agents](docs/agents.md): cómo se cambia cada agente y qué pasa con sus valores predeterminados
- [How it works](docs/how-it-works.md): detección, el selector, diálogos de confirmación, tiempos
- [Safety and limits](docs/safety.md): las reglas que sigue la app antes de enviar una tecla
- [Development](docs/development.md): compilar, probar, añadir un idioma

## Idiomas

La app sigue el idioma de tu sistema. Está disponible en inglés, coreano, japonés, chino simplificado, español, francés, alemán, portugués y árabe. Todos los idiomas excepto el inglés y el coreano son traducciones automáticas, y se agradecen las correcciones.

## Contribuir

Se agradecen los informes de errores, las correcciones para nuevas versiones de los agentes y las correcciones de traducción. Consulta [CONTRIBUTING.md](CONTRIBUTING.md).

## Licencia

[MIT](LICENSE)

Slash Command es un proyecto independiente. No está afiliado a Anthropic, OpenAI, xAI, Cursor, Google, OpenCode ni a los creadores de las terminales que admite. Sus nombres de producto se usan solo para describir la compatibilidad.
