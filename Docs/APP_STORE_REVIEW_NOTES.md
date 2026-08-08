# App Store Review Notes — Cool Down

## What the app does

Cool Down is a menu bar utility that:

1. Displays `ProcessInfo.thermalState` as thermal pressure
2. Lists approximate hot processes
3. Lets the user quit a process they select to reduce heat
4. Optionally notifies when pressure is serious/critical

## What the app does NOT do

- No SMC / IOKit fan speed writes
- No privileged helper / root daemon
- No kernel extensions
- No claims of direct hardware fan control

## Test plan for reviewers

1. Launch Cool Down — only a menu bar icon appears (no Dock icon).
2. Open the popover — thermal pressure and tips are visible.
3. Open Settings — toggles for menu bar label, launch at login, alerts.
4. Optional: run a CPU-heavy task and confirm pressure/process list updates.
