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

## ทำงานพร้อมกันหลายคน (Rojo)

> กฎหลัก: **ห้ามมี 2 คนต่อ Rojo เข้า place เดียวกัน โดย sync โฟลเดอร์เดียวกัน** ไม่งั้นโค้ดจะทับกันไปมา

### วิธีที่ 1: ต่อเข้า place ของตัวเอง ⭐ แนะนำ

ทุกคนต่อ Rojo พร้อมกันได้ เพราะใช้คนละ place

1. ใน Studio เปิดเกมของกลุ่ม → **File → Save to File As…** → บันทึกเป็น `dev.rbxl` ในโฟลเดอร์นี้
   (`*.rbxl` อยู่ใน `.gitignore` แล้ว จะไม่ขึ้น Git)
2. เวลาเขียนโค้ด: เปิด `dev.rbxl` → `rojo serve` → กด **Connect**
3. รวมงานกันผ่าน Git (แตก branch → push → เปิด Pull Request)
4. ตอนจะอัปเกมจริง: **คนเดียว** `git pull` โค้ดล่าสุด → เปิดเกมของกลุ่ม → `rojo serve` → Connect → **File → Publish to Roblox**

- ✅ ไม่มีทางทับกัน และเทสพังได้ไม่กระทบเกมจริง
- ❌ ไม่เห็นงานเพื่อนจนกว่าจะ `git pull`

### วิธีที่ 2: ต่อเข้า Team Create พร้อมกัน แต่แบ่งโฟลเดอร์

ใช้เมื่ออยากทำในเกมของกลุ่มพร้อมกันแบบเรียลไทม์ แต่ละคนดูแลโฟลเดอร์ไม่ซ้ำกัน และใช้ project file ของตัวเอง

ตัวอย่าง: คนหนึ่งทำระบบการ์ด อีกคนทำ UI

`cards.project.json`
```json
{
  "name": "TCG-Blox-Cards",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "$ignoreUnknownInstances": true,
      "Shared": {
        "$ignoreUnknownInstances": true,
        "Cards": { "$path": "src/shared/Cards" }
      }
    },
    "ServerScriptService": {
      "$ignoreUnknownInstances": true,
      "CardServer": { "$path": "src/server/cards" }
    }
  }
}
```

`ui.project.json`
```json
{
  "name": "TCG-Blox-UI",
  "tree": {
    "$className": "DataModel",
    "StarterPlayer": {
      "$ignoreUnknownInstances": true,
      "StarterPlayerScripts": {
        "$ignoreUnknownInstances": true,
        "UI": { "$path": "src/client/ui" }
      }
    }
  }
}
```

แต่ละคนรันเฉพาะไฟล์ของตัวเอง:
```
rojo serve cards.project.json   # คนทำการ์ด
rojo serve ui.project.json      # คนทำ UI
```

⚠️ ข้อควรระวัง
- **ห้ามมีโฟลเดอร์ที่ 2 project file map ซ้ำกัน**
- โค้ดที่ใช้ร่วมกัน (เช่น `src/shared` ทั้งก้อน) ให้คนเดียวดูแล หรือแก้ผ่าน Git แล้วให้คนนั้นเป็นคน sync
- ใส่ `"$ignoreUnknownInstances": true` **ทุกชั้น** ไม่งั้น Rojo ของคนหนึ่งจะลบของที่อีกคน sync เข้ามา

**สรุป:** เริ่มด้วยวิธีที่ 1 ถ้าอยากเห็นงานกันสดๆ ค่อยเปลี่ยนเป็นวิธีที่ 2

## Team rules

- อย่าแก้สคริปต์ที่ Rojo จัดการใน Studio เพราะ sync รอบถัดไปจะเขียนทับ
- ทำงานบน branch ของตัวเอง แล้วเปิด Pull Request
- ของที่สร้างใน Studio (แมพ, Model, UI ที่วางในฉาก) อยู่ใน Team Create ไม่ได้อยู่ใน repo นี้
- ถ้าเผลอทำเกมพัง: Creator Hub → หน้าเกม → **Version History** แล้วย้อนเวอร์ชันได้
