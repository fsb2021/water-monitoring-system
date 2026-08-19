# Water Monitoring System

This repository contains the mobile app, embedded firmware, and backend services used by the water monitoring project.

## Project layout

- `mobile/`  
  Flutter mobile/web/desktop application source and platform projects.
- `firmware/stm32/`  
  STM32 firmware sources and project files (`main.c`, `adc_test.ioc`).
- `firmware/esp8266/`  
  ESP8266 gateway firmware (`esp8266_gateway.ino`).
- `backend/functions/`  
  Firebase Cloud Functions backend.
- `docs/`  
  Repository and architecture documentation.

See `/home/runner/work/water-monitoring-system/water-monitoring-system/docs/repository_structure.md` for detailed module organization.

## Run the mobile app

```bash
cd /home/runner/work/water-monitoring-system/water-monitoring-system/mobile
flutter pub get
flutter run
```

## Run Firebase Functions locally

```bash
cd /home/runner/work/water-monitoring-system/water-monitoring-system
firebase emulators:start --only functions
```
