# TCG Blox (เกลือBlox)

Roblox game by the group **TCG Blox(เกลือไปด้วยกัน)**, managed with [Rojo](https://rojo.space).

## Setup (once)

1. Install [Aftman](https://github.com/LPGhatguy/aftman), then in this folder run:
   ```
   aftman install
   ```
2. Install the Rojo plugin in Roblox Studio (`rojo plugin install`).
3. Install the recommended VS Code extensions (Rojo, Luau LSP).

## Daily workflow

```
git pull
rojo serve
```

In Studio, open **TCG Blox (เกลือBlox)** from Group Experiences and press **Connect** in the Rojo plugin.
Edit code in VS Code, then commit and push.

## Where things live

| Folder | In Studio |
|---|---|
| `src/server` | ServerScriptService.Server |
| `src/client` | StarterPlayer.StarterPlayerScripts.Client |
| `src/shared` | ReplicatedStorage.Shared |

Maps, models and UI are built in Studio (Team Create), not in this repo.

## Team rules

- Do **not** edit Rojo-managed scripts inside Studio — the next sync overwrites them.
- Only **one person** connects Rojo to the group's Team Create place at a time.
- Work on your own branch and open a Pull Request.
