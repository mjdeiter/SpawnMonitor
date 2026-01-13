# SpawnMonitor

**Originally created by Alektra <Lederhosen>**

[![Buy Me a Coffee](https://img.shields.io/badge/Support-Buy%20Me%20a%20Coffee-ffdd00?logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/shablagu)


**Description:**  
A full-featured named camp monitor for EverQuest using MQ2 and ImGui. Tracks NPC spawns based on exact or partial name matching, supports multi-named monitoring, audio alerts, and a center-screen HUD overlay for instant notifications.

<img width="465" height="648" alt="image" src="https://github.com/user-attachments/assets/93484bb0-230d-405a-b8a8-5d827662b26d" />


---

## Features
- Exact and partial NPC name matching.
- Multi-named tracking with automatic removal when out of range.
- Configurable scan radius and vertical range.
- Audio alerts: beep or custom sound files.
- Center-screen overlay alerts with customizable duration and color.
- Persistent profiles for different zones or scenarios.
- ImGui-based GUI with Monitor, Config, and Profile tabs.
- Debug tools for scanning current target and testing alerts.

---

## Installation
1. Place `SpawnMonitor.lua` in your MQ2 `scripts` directory.
2. Ensure MQ2 and ImGui are loaded.
3. Run in-game with `/lua run SpawnMonitor`.

---

## Usage
- **Monitor Tab:** Shows active detected nameds and status.
- **Config Tab:** Configure scan radius, Z-range, audio alerts, and watchlists.
- **Profiles Tab:** Manage multiple watch profiles by zone or custom name.
- Arm the monitor to start scanning for nameds.

---

## Configuration
Settings and profiles are saved to `SpawnMonitor.ini` in your MQ2 config directory.  
- Exact matches require the full spawn name.  
- Partial matches trigger on any substring of a spawn's name.  

---

## License
[MIT License](LICENSE) 
