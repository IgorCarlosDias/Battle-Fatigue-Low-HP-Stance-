# Battle Fatigue (Low HP Stance) — Dragon Ball: Sparking! ZERO

[![Game](https://img.shields.io/badge/Game-Dragon%20Ball%3A%20Sparking!%20ZERO-orange)](https://github.com/IgorCarlosDias/Battle-Fatigue-Low-HP-Stance-)
[![Author](https://img.shields.io/badge/Author-Zayko96-blueviolet)](https://gamebanana.com/members/Zayko96)
[![Mod Manager](https://img.shields.io/badge/Unverum-Compatible-brightgreen)](https://gamebanana.com/tools/18251)
[![Loader](https://img.shields.io/badge/Requires-UE4SS-blue)](https://github.com/UE4SS-RE/RE-UE4SS)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **Created by:** **Zayko96**  
> Inspired by the classic **Budokai Tenkaichi 3** exhaustion mechanic.

---

### 📖 About the Mod / Sobre o Mod

**EN:**  
Inspired by **Budokai Tenkaichi 3**, where characters visibly showed severe exhaustion when their health was low. In *Sparking! ZERO*, fighters remain completely composed and relaxed even when they are 1 hit away from defeat.  
**Battle Fatigue** restores that classic BT3 immersion: whenever any fighter enters their **last (red) health bar (`HP <= 10,000`)**, their idle stance dynamically transitions to the panting/exhausted posture (**both on the ground and hovering in the air**).  
It is **100% visual only**, with **zero input delay, zero paralysis, and zero control lock**.

**PT-BR:**  
Inspirado no clássico **Budokai Tenkaichi 3**, onde os personagens ficavam visivelmente ofegantes e exaustos com pouca vida. No *Sparking! ZERO*, os lutadores mantêm a postura normal e relaxada mesmo estando a um golpe da derrota.  
O mod **Battle Fatigue** traz essa imersão de volta: quando qualquer lutador entra na **última barra de vida (vermelha / `HP <= 10.000`)**, a postura parada (*idle*) muda para a animação de cansaço/ofegante (**no chão e flutuando no ar**).  
É **100% visual**, sem delay nos comandos e sem travar o personagem.

---

## ⚡ Features / Recursos

- **BT3-Style Immersion:** Automatically triggers on the final health bar (`HP <= 10,000` / Red Bar).
- **Ground & Mid-Air Support:** Works seamlessly whether your character is grounded or floating mid-air.
- **100% Visual / Zero Input Delay:** Hooks the engine's visual animation cache (`KoratCharacterLocomotionComponent`). Moving, dashing, blocking, vanishes, counters, charging ki, or attacking immediately cancels the pose on the exact same frame.
- **Universal Compatibility:** Works for all 180+ base roster characters, DLCs, transformations, and custom modded characters (no `.pak` / `.utoc` asset conflicts).
- **Online & Replay Safe:** Automatically disables itself in online matches and replays to prevent desyncs.
- **Zero Performance Hit:** Lightweight Lua hook via UE4SS, zero frame drops.

---

## 📋 Requirements / Requisitos

- **Dragon Ball: Sparking! ZERO** (PC — Steam / Windows 64-bit)
- **Unverum** *(Recommended / 1-click install)* **OR** **UE4SS (v3.0+)** installed in `SparkingZERO\Binaries\Win64\`.

---

## 🛠️ Installation / Instalação

### Option 1 — Unverum (Recommended / 1-Click)
1. Download `Battle-Fatigue-Low-HP-Stance-v1.1.0.zip`.
2. Drag and drop the `.zip` file directly into your **Unverum** window.
3. Check **Battle Fatigue (Low HP Stance)** and click **Launch Game**.

### Option 2 — Manual (UE4SS)
1. Make sure **UE4SS** is installed in `<GameDirectory>\SparkingZERO\Binaries\Win64\`.
2. Open the downloaded `.zip` file.
3. Extract the `ue4ss\BattleFatigue` folder into:
   ```text
   <GameDirectory>\SparkingZERO\Binaries\Win64\Mods\BattleFatigue\
   ```
4. Verify that `main.lua` is located at `.../Mods/BattleFatigue/Scripts/main.lua`.
5. Launch the game (`enabled.txt` inside the folder enables the mod automatically).

---

## ⚙️ Configuration & In-Game Hotkeys

You can easily tweak settings in `ue4ss/BattleFatigue/Scripts/config.lua`:

| Setting | Default | Description |
| :--- | :--- | :--- |
| `enabled` | `true` | Enable or disable the mod |
| `hpThreshold` | `10000.0` | Health trigger threshold (`10000` = last red bar) |
| `enablePlayer1` | `true` | Apply to Player 1 |
| `enablePlayer2` | `true` | Apply to Player 2 / CPU |
| `groundOnly` | `false` | `false` = ground & air; `true` = ground only |
| `maxIdleSpeed` | `25.0` | Velocity threshold to consider idle |
| `enableHotkeys` | `true` | Enable live hotkeys below |

### In-Game Hotkeys:
- **`F7`** — Toggle Battle Fatigue ON / OFF live.
- **`F8`** — Hot-reload `config.lua` without restarting the game.
- **`F9`** — Dump live animation & health debug info to `%TEMP%\BattleFatigue.log`.

---

## 👤 Credits & Author

- **Author / Mod Creator:** **Zayko96**
- **Repository:** [GitHub - Battle-Fatigue-Low-HP-Stance-](https://github.com/IgorCarlosDias/Battle-Fatigue-Low-HP-Stance-)
- **Feedback & Bug Reports:** Please report any issues or suggestions on the GameBanana submission page or GitHub Issues!

---

## 📄 License

Released under the [MIT License](LICENSE).
