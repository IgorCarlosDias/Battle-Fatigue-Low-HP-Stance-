# Battle Fatigue (Low HP Stance) — Dragon Ball: Sparking! ZERO

[![Game](https://img.shields.io/badge/Game-Dragon%20Ball%3A%20Sparking!%20ZERO-orange)](https://github.com/IgorCarlosDias/Battle-Fatigue-Low-HP-Stance-)
[![Mod Manager](https://img.shields.io/badge/Unverum-Compatible-brightgreen)](https://gamebanana.com/tools/7162)
[![Loader](https://img.shields.io/badge/Requires-UE4SS-blue)](https://github.com/UE4SS-RE/RE-UE4SS)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **EN:** Makes **all characters** assume the exhausted/panting battle stance when standing still (**on the ground or hovering in the air**) during their **last (red) health bar** — **100% visual**, with **zero input lock or gameplay delay**.
>
> **PT-BR:** Faz com que **todos os personagens** assumam a postura de exaustão/ofegante ao ficarem parados (**no chão ou flutuando no ar**) na **última barra de vida (vermelha)** — **100% visual**, sem travar controles nem atrasar comandos.

---

## Features / Recursos

- **Anime-Accurate Low HP Immersion:** Triggers automatically when a fighter enters the last health bar (`HP <= 10,000`).
- **Ground & Air Support:** Works both while standing still on the ground and while hovering idle in the air.
- **100% Visual / Zero Control Lock:** Hooks only the locomotion animation cache (`KoratCharacterLocomotionComponent`). Moving the stick, dashing, guarding, charging Ki, or attacking cancels the stance on the very same frame.
- **Universal Compatibility:** Works with **all vanilla characters** and **custom character mods** (ZeroSpark / SZModLib / new slots) with zero `.pak` / `.utoc` asset conflicts.
- **Online & Replay Safe:** Automatically disables itself in online matches and replays to prevent desyncs.
- **Zero Performance Overhead:** Uses cached component references and synchronous hooks (no per-frame `FindAllOf`, no disk logging by default).

---

## Requirements / Requisitos

- **Dragon Ball: Sparking! ZERO** (PC — Windows 64-bit)
- **Unverum** *(recommended — installs and configures UE4SS automatically)* **OR** **UE4SS (v3.0+)** installed manually in `SparkingZERO\Binaries\Win64\`.
- **Not required:** Does **not** require UTOC Signature Bypass, SZModLib, ZeroSpark, or ASI Loader.

---

## Installation / Instalação

### Option 1 — Unverum (Recommended / 1-Click)
1. Download the latest `Battle-Fatigue-Low-HP-Stance-vX.X.X.zip` from the [**Releases**](https://github.com/IgorCarlosDias/Battle-Fatigue-Low-HP-Stance-/releases) page.
2. Drag and drop the `.zip` into **Unverum** (or extract it into `Unverum\Mods\Dragon Ball Sparking! ZERO\Battle Fatigue (Low HP Stance)\`).
3. Enable **Battle Fatigue (Low HP Stance)** in Unverum and click **Launch**.

### Option 2 — Manual (UE4SS without Unverum)
1. Make sure **UE4SS** is installed in `<GameFolder>\SparkingZERO\Binaries\Win64\`.
2. Copy the `ue4ss\BattleFatigue` folder from the release `.zip` into `<GameFolder>\SparkingZERO\Binaries\Win64\Mods\BattleFatigue\`.
3. Launch the game (`enabled.txt` automatically enables the mod).

---

## Configuration & Hotkeys / Configuração e Atalhos

Edit `ue4ss/BattleFatigue/Scripts/config.lua` to customize:

| Option | Default | Description |
| :--- | :--- | :--- |
| `enabled` | `true` | Enable or disable the mod at startup |
| `hpThreshold` | `10000.0` | HP threshold (10,000 = last red health bar) |
| `enablePlayer1` / `enablePlayer2` | `true` | Apply to Player 1 and/or Player 2 / CPU |
| `groundOnly` | `false` | `false` = ground & air; `true` = ground only |
| `maxIdleSpeed` | `25.0` | Maximum 3D velocity to consider idle |
| `enableHotkeys` | `true` | Enable `F7`, `F8`, `F9` live shortcuts |
| `logDebug` | `false` | Write diagnostics to `%TEMP%\BattleFatigue.log` |

### In-Game Hotkeys
- **`F7`** — Toggle Battle Fatigue ON/OFF live.
- **`F8`** — Hot-reload `config.lua` and `fatigue_controller.lua` live without restarting the game.
- **`F9`** — Write a live fighter/animation diagnostic snapshot to `%TEMP%\BattleFatigue.log`.

---

## Building the Release `.zip`

```bash
python scripts/build_zip.py
```

Generates `dist/Battle-Fatigue-Low-HP-Stance-v1.0.0.zip` ready for Unverum and manual UE4SS installation.

---

## License

Released under the [MIT License](LICENSE).
